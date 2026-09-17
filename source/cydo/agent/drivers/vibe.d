module cydo.agent.drivers.vibe;

import core.time : Duration, seconds;

import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.exception : enforce;
import std.path : buildPath, isAbsolute;

import ae.net.asockets : IConnection, onNextTick, socketManager;
import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher,
	RPCFlatten, RPCName, RPCNamedParams;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;
import ae.utils.serialization.store : SerializedObject;

version (unittest) import ae.net.asockets : ConnectionState, DisconnectType;
version (unittest) import ae.sys.data : Data;
version (unittest) import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;

import cydo.agent.contract : Agent, DiscoveredSession, InterruptedToolCallRepair,
	OneShotHandle, PersistedHistoryBoundary, RewindResult, SessionConfig,
	SessionMeta;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt;
import cydo.protocol : ContentBlock, extractContentText, ItemCompletedEvent,
	ItemDeltaEvent, ItemResultEvent, ItemStartedEvent, makeUnrecognizedEvent,
	ProcessExitEvent, ProcessStderrEvent, SessionCompactedEvent, SessionInitEvent,
	TranslatedEvent, TurnResultEvent, TurnStopEvent, UsageInfo;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox : cydoBinaryDir, cydoBinaryPath,
	effectiveEnvValue, executableMountPaths, resolveExecutablePath;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;

private alias SO = SerializedObject!(immutable char);

// ---------------------------------------------------------------------------
// ACP wire structs — protocol v1, verified against vibe-acp 2.25.4
// (see docs/research/vibe-acp-wire.md and docs/research/acp/SPEC_v1.md).
// ---------------------------------------------------------------------------

private struct VibeFsCapabilities
{
	bool readTextFile;
	bool writeTextFile;
}

private struct VibeClientCapabilities
{
	VibeFsCapabilities fs;
	bool terminal;
}

private struct VibeClientInfo
{
	string name;
	@JSONName("version") string version_;
}

private struct VibeInitializeParams
{
	int protocolVersion;
	VibeClientCapabilities clientCapabilities;
	@JSONOptional VibeClientInfo clientInfo;
}

@JSONPartial
private struct VibeInitializeResponse
{
	int protocolVersion;
}

private struct EnvVariable
{
	string name;
	string value;
}

private struct McpServerStdio
{
	string type = "stdio";
	string name;
	string command;
	string[] args;
	EnvVariable[] env;
}

private struct NewSessionParams
{
	string cwd;
	McpServerStdio[] mcpServers;
}

@JSONPartial
private struct NewSessionResponse
{
	string sessionId;
}

private struct LoadSessionParams
{
	string sessionId;
	string cwd;
	McpServerStdio[] mcpServers;
}

private struct VibePromptBlock
{
	string type = "text";
	string text;
}

private struct PromptParams
{
	string sessionId;
	VibePromptBlock[] prompt;
}

private struct VibePromptUsage
{
	@JSONOptional int total_tokens;
	@JSONOptional int input_tokens;
	@JSONOptional int output_tokens;
	@JSONOptional int thought_tokens;
	@JSONOptional int cached_read_tokens;
	@JSONOptional int cached_write_tokens;
}

@JSONPartial
private struct PromptResponse
{
	string stopReason;
	@JSONOptional VibePromptUsage usage;
}

private struct CancelParams
{
	string sessionId;
}

@JSONPartial
private struct VibeSessionUpdate
{
	string sessionUpdate;
	@JSONOptional string messageId;       // ContentChunk correlation key
	@JSONOptional JSONFragment content;   // ContentChunk block / ToolCallContent[]
	@JSONOptional string toolCallId;
	@JSONOptional string title;
	@JSONOptional string kind;
	@JSONOptional string status;
	@JSONOptional JSONFragment rawInput;
	@JSONOptional JSONFragment rawOutput;
	@JSONName("_meta") @JSONOptional JSONFragment meta;
}

@RPCFlatten @JSONPartial
private struct SessionUpdateParams
{
	string sessionId;
	SO update;
}

@RPCFlatten @JSONPartial
private struct PermissionRequestParams
{
	string sessionId;
	@JSONPartial struct VibeToolCallRef { string toolCallId; }
	VibeToolCallRef toolCall;
}

private struct PermissionOutcome
{
	string outcome = "selected";
	@JSONOptional string optionId;

	static PermissionOutcome allowOnce()
	{
		PermissionOutcome result;
		result.optionId = "allow_once";
		return result;
	}

	static PermissionOutcome cancelled()
	{
		PermissionOutcome result;
		result.outcome = "cancelled";
		return result;
	}
}

// ---------------------------------------------------------------------------
// VibeSessionHandler — per-session event sink wired up by VibeSession.
// ---------------------------------------------------------------------------

private interface VibeSessionHandler
{
	void handleSessionUpdate(SessionUpdateParams params);
	Promise!PermissionOutcome handlePermissionRequest(PermissionRequestParams params);
	void handleStderr(string line);
	void handleStartupFailure(Exception error);
	void handleExit(int status);
}

// ---------------------------------------------------------------------------
// IVibeAcpServer — methods the vibe-acp process calls on us.
// ---------------------------------------------------------------------------

@RPCNamedParams
private interface IVibeAcpServer
{
	// Agent → client streaming notification.
	@RPCName("session/update") Promise!void sessionUpdate(SessionUpdateParams params);

	// Agent → client permission request (auto-approved with allow_once).
	@RPCName("session/request_permission") Promise!PermissionOutcome
		requestPermission(PermissionRequestParams params);
}

private class VibeServerRouter : IVibeAcpServer
{
	private VibeAcpProcess server;

	this(VibeAcpProcess server) { this.server = server; }

	Promise!void sessionUpdate(SessionUpdateParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			(*session).handleSessionUpdate(params);
		return resolve();
	}

	Promise!PermissionOutcome requestPermission(PermissionRequestParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handlePermissionRequest(params);
		return resolve(PermissionOutcome.cancelled());
	}
}

// ---------------------------------------------------------------------------
// VibeAcpProcess — manages a vibe-acp JSON-RPC 2.0 subprocess (NDJSON stdio).
// One instance per task session; the v1 handshake (`initialize`) is sent from
// the constructor and gates the ready state.
// ---------------------------------------------------------------------------

class VibeAcpProcess
{
	private AgentProcess process;
	private JsonRpcCodec codec;
	private JsonRpcDispatcher!IVibeAcpServer serverDispatcher;

	enum State { starting, initializing, ready, failed, dead }
	private State state_ = State.starting;

	// Session routing: sessionId → handler.
	private VibeSessionHandler[string] sessions;

	// Handler attached before its server-assigned session ID is adopted
	// (new sessions learn the ID from the session/new response); routes
	// startup failures, stderr, and exit until registerSession takes over.
	private VibeSessionHandler pendingSession;

	// Actions queued until the agent reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args, string[string] env = null, string workDir = null,
		string logName = "vibe")
	{
		process = new AgentProcess(args, env, workDir, false,
			FramingMode.ndjson, logName);

		IConnection connection = process.connection;
		codec = new JsonRpcCodec(connection);
		auto router = new VibeServerRouter(this);
		serverDispatcher = jsonRpcDispatcher!IVibeAcpServer(router);
		codec.handleRequest = &serverDispatcher.dispatch;

		process.onStderrLine = (string line) {
			bool routed = false;
			if (pendingSession !is null)
			{
				pendingSession.handleStderr(line);
				routed = true;
			}
			foreach (session; sessions)
			{
				session.handleStderr(line);
				routed = true;
			}
			if (!routed)
			{
				import std.stdio : stderr;
				stderr.writeln("[vibe/pre-session-stderr] " ~ line);
			}
		};

		process.onExit = (int status) {
			state_ = State.dead;
			if (pendingSession !is null)
				pendingSession.handleExit(status);
			foreach (session; sessions)
				session.handleExit(status);
		};

		sendInitialize();
	}

	version (unittest) private this(IConnection connection,
		bool sendInitialize)
	{
		initializeTestVibeAcpProcess(this, connection, sendInitialize);
	}

	@property State state() { return state_; }
	@property bool dead()
	{
		return state_ == State.failed || state_ == State.dead || process.dead;
	}

	void setPendingSession(VibeSessionHandler handler)
	{
		pendingSession = handler;
	}

	void forgetSession(VibeSessionHandler handler)
	{
		if (pendingSession is handler)
			pendingSession = null;
	}

	void registerSession(string sessionId, VibeSessionHandler handler)
	{
		if (pendingSession is handler)
			pendingSession = null;
		sessions[sessionId] = handler;
	}

	void unregisterSession(string sessionId)
	{
		sessions.remove(sessionId);
	}

	/// Terminate the underlying vibe process and defer exit handlers until
	/// the process has actually exited. Copied from SdkProcess.shutdown:
	/// processes may spawn children that hold the stdout pipe open,
	/// preventing AgentProcess.tryFireExit from ever firing. We use
	/// killAfterTimeout to force-close all pipes after 3 s via daemon
	/// timers, which guarantees the event loop drains even if orphaned
	/// children hold write-ends of the stdout/stderr pipes open.
	///
	/// NOTE: we deliberately do NOT call asyncWait here. If the AgentProcess
	/// asyncWait (installed in the constructor) fires first it reaps the pid
	/// via waitpid(2), making any subsequent asyncWait for the same pid
	/// return ECHILD indefinitely — leaving a non-daemon ThreadAnchor that
	/// never closes and hangs the event loop forever.
	void shutdown()
	{
		if (dead)
			return;
		state_ = State.dead;

		// Snapshot handlers — the registry may be mutated by handleExit.
		VibeSessionHandler[] handlers;
		if (pendingSession !is null)
			handlers ~= pendingSession;
		handlers ~= sessions.values;
		bool fired = false;
		void fireExit()
		{
			if (fired)
				return;
			fired = true;
			foreach (handler; handlers)
				handler.handleExit(1);
		}

		// Route the existing pipe-drain exit notification through fireExit.
		process.onExit = (int) { fireExit(); };
		process.closeStdin();
		process.terminate();

		// Daemon timers: SIGKILL at +3 s, forceClosePipes at +3.5 s.
		// These are daemon so they do not prevent the event loop from
		// exiting, but the non-daemon stdout/stderr FileConnections keep it
		// alive until the pipes actually close.
		process.killAfterTimeout(3.seconds);
	}

	/// Queue an action for when the agent is ready. Runs immediately if
	/// ready; drops when the agent already failed or died.
	void onReady(void delegate() dg)
	{
		if (state_ == State.ready)
			dg();
		else if (state_ != State.failed && state_ != State.dead)
			readyQueue ~= dg;
	}

	/// Send a JSON-RPC request, returning a promise for the response.
	Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		return codec.sendRequest(buildRequest(method, params));
	}

	/// Send a JSON-RPC notification (no id, no response expected).
	void sendNotification(string method, string params)
	{
		codec.sendNotification(buildRequest(method, params));
	}

	private static auto buildRequest(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = jsonParse!SO(params);
		return req;
	}

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		VibeInitializeParams params;
		params.protocolVersion = 1;
		params.clientCapabilities.fs.readTextFile = true;
		params.clientCapabilities.fs.writeTextFile = true;
		params.clientCapabilities.terminal = false;
		VibeClientInfo clientInfo;
		clientInfo.name = "cydo";
		clientInfo.version_ = "0.1.0";
		params.clientInfo = clientInfo;
		sendRequest("initialize", toJson(params))
		.then((JsonRpcResponse resp) {
			if (resp.isError)
			{
				failStartup(new Exception(resp.error.get.message));
				return;
			}
			int protocolVersion = 0;
			try
			{
				auto ir = resp.result.deserializeTo!VibeInitializeResponse();
				protocolVersion = ir.protocolVersion;
			}
			catch (Exception) {}
			if (protocolVersion != 1)
			{
				failStartup(new Exception("vibe ACP protocol version is unsupported"));
				return;
			}
			state_ = State.ready;
			auto queue = readyQueue;
			readyQueue = null;
			foreach (dg; queue)
				dg();
		})
		.except((Exception e) {
			failStartup(e);
		});
	}

	private void failStartup(Exception error)
	{
		if (state_ == State.failed || state_ == State.dead)
			return;
		state_ = State.failed;
		readyQueue = null;
		if (pendingSession !is null)
			pendingSession.handleStartupFailure(error);
		auto handlers = sessions.values;
		foreach (handler; handlers)
			handler.handleStartupFailure(error);
	}
}

version (unittest) private final class TestVibeAcpProcess : VibeAcpProcess
{
	this(IConnection connection, bool sendInitialize)
	{
		super(connection, sendInitialize);
	}

	override @property bool dead()
	{
		return state_ == State.failed || state_ == State.dead;
	}

	override void shutdown()
	{
		if (dead)
			return;
		state_ = State.dead;
		VibeSessionHandler[] handlers;
		if (pendingSession !is null)
			handlers ~= pendingSession;
		handlers ~= sessions.values;
		foreach (handler; handlers)
			handler.handleExit(1);
	}
}

version (unittest) private void initializeTestVibeAcpProcess(VibeAcpProcess server,
	IConnection connection, bool sendInitialize)
{
	server.codec = new JsonRpcCodec(connection);
	auto router = new VibeServerRouter(server);
	server.serverDispatcher = jsonRpcDispatcher!IVibeAcpServer(router);
	server.codec.handleRequest = &server.serverDispatcher.dispatch;
	if (sendInitialize)
		server.sendInitialize();
	else
		server.state_ = VibeAcpProcess.State.ready;
}

version (unittest) private VibeAcpProcess makeTestVibeAcpProcess(
	IConnection connection, bool sendInitialize = false)
{
	return new TestVibeAcpProcess(connection, sendInitialize);
}

// ---------------------------------------------------------------------------
// VibeAgent — Agent descriptor for Mistral Vibe (`vibe-acp`, ACP wire
// protocol v1). Sessions run one vibe-acp process each; the CyDo MCP server
// is delivered via the session/new handshake, and the native-history profile
// is bootstrapped with a config.toml that suppresses updates and telemetry.
// ---------------------------------------------------------------------------

class VibeAgent : Agent
{
	private ModelSpec[string] modelAliasOverrides;

	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
		import std.process : environment;

		foreach (path; executableMountPaths(resolveExecutablePath(executableName(env), env)))
			paths.requireReadVisible(path,
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "vibe",
					"Vibe executable"));
		paths.requireReadVisible(cydoBinaryDir(),
			SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "vibe",
				"CyDo binary"));

		// Pass through vibe-required env vars so they survive sandboxing.
		void passthrough(string key)
		{
			if (key in env)
				return;
			auto val = environment.get(key, "");
			if (val.length > 0)
				env[key] = val;
		}

		passthrough("MISTRAL_API_KEY");
		passthrough("VIBE_HOME");
		passthrough("HTTPS_PROXY");
		passthrough("NO_PROXY");
		passthrough("PATH");
	}

	@property string gitName() { return "Mistral Vibe"; }

	@property string gitEmail() { return "noreply@mistral.ai"; }

	@property AgentDriver driver() { return AgentDriver.vibe; }

	@property NativeHistoryRule nativeHistoryRule()
	{
		return NativeHistoryRule(AgentDriver.vibe, "VIBE_HOME", ".vibe", null);
	}

	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_VIBE_BIN", "vibe-acp");
	}

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		auto model = config.model;
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");

		bootstrapVibeProfile(launch, config);

		// S2-verified: vibe-acp is stdio-only; no launch flags.
		auto vibeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		string[] vibeArgs = [vibeBin];
		string[] args = launch.cmdPrefix !is null
			? launch.cmdPrefix ~ vibeArgs : vibeArgs;

		auto server = new VibeAcpProcess(args, null, null, "vibe");
		return attachSession(server, tid, resumeSessionId, model, workDir, config);
	}

	/// Write the profile bootstrap files when a native-history profile root
	/// is present: config.toml (only when absent, so a shared user profile is
	/// never clobbered) suppressing update checks and telemetry, pinning the
	/// active model; trusted_folders.toml (only when absent and the task work
	/// dir is absolute) so sessions start trusted.
	private void bootstrapVibeProfile(ProcessLaunch launch, SessionConfig config)
	{
		if (launch.nativeHistoryProfile.root.length == 0)
			return;
		enforce(launch.nativeHistoryProfile.driver == driver,
			"Vibe history profile driver does not match Mistral Vibe");

		import std.file : exists, mkdirRecurse, write;

		auto root = launch.nativeHistoryProfile.root;
		mkdirRecurse(root);

		auto configPath = buildPath(root, "config.toml");
		if (!exists(configPath))
		{
			string contents = "# managed by CyDo — per-task agent profile\n"
				~ "enable_update_checks = false\n"
				~ "enable_telemetry = false\n";
			auto model = resolveModelSpec(config.model).model;
			if (model.length > 0)
				contents ~= "active_model = \"" ~ model ~ "\"\n";
			write(configPath, contents);
		}

		auto trustedPath = buildPath(root, "trusted_folders.toml");
		if (!exists(trustedPath))
		{
			auto workDir = launch.workDir.length > 0
				? launch.workDir : config.workDir;
			if (workDir.isAbsolute)
				write(trustedPath, "trusted = [\"" ~ workDir ~ "\"]\n");
		}
	}

	string extractResultText(string line)
	{
		if (!line.canFind(`"turn/result"`))
			return "";

		@JSONPartial
		static struct ResultProbe
		{
			string type;
			string result;
		}

		try
		{
			auto probe = jsonParse!ResultProbe(line);
			if (probe.type == "turn/result")
				return probe.result;
		}
		catch (Exception) {}
		return "";
	}

	string extractAssistantText(string line)
	{
		if (!line.canFind(`"item/started"`))
			return "";

		@JSONPartial
		static struct ItemStartedProbe { string type; string item_type; string text; }

		try
		{
			auto probe = jsonParse!ItemStartedProbe(line);
			if (probe.type == "item/started" && probe.item_type == "text"
				&& probe.text.length > 0)
				return probe.text;
		}
		catch (Exception) {}
		return "";
	}

	string extractUserText(string line)
	{
		if (!line.canFind(`"user_message"`))
			return "";

		@JSONPartial
		static struct UserProbe
		{
			string type;
			string item_type;
			ContentBlock[] content;
		}

		try
		{
			auto probe = jsonParse!UserProbe(line);
			if (probe.type == "item/started" && probe.item_type == "user_message")
				return extractContentText(probe.content);
		}
		catch (Exception) {}
		return "";
	}

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "devstral-small";
			case "medium": return "mistral-medium-3.5";
			case "large":  return "mistral-medium-3.5";
			default:       return modelClass; // pass through unknown aliases
		}
	}

	ModelSpec resolveModelSpec(string modelClass)
	{
		ModelSpec spec;
		if (auto p = modelClass in modelAliasOverrides)
			spec = *p;
		if (spec.model.length == 0)
			spec.model = defaultModelForClass(modelClass);
		return spec;
	}

	// ---- History / fork (Part 4: vibe's on-disk session format) ----

	string historyPath(string sessionId, const ref NativeHistoryProfile profile)
	{
		return null;
	}

	void registerHistoryPath(string sessionId, string path,
		const ref NativeHistoryProfile profile)
	{
	}

	string createHistoryForkDestination(string sessionId, string sourceHistoryPath,
		const ref NativeHistoryProfile profile)
	{
		return null;
	}

	void resetHistoryReplay()
	{
	}

	TranslatedEvent[] translateHistoryLine(string line, int lineNum)
	{
		return [];
	}

	@property string lastMcpConfigPath() { return null; }

	string rewriteSessionId(string line, string oldId, string newId)
	{
		return line;
	}

	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content,
		int lineOffset = 0)
	{
		return [];
	}

	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText)
	{
		return null;
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		return false;
	}

	bool isForkableLine(string line) { return false; }

	TranslatedEvent[] translateLiveEvent(string rawLine)
	{
		// VibeSession emits agnostic-format events natively; only stderr/exit
		// need renaming. Everything else passes through.
		@JSONPartial static struct TypeProbe { string type; }
		try
		{
			auto probe = jsonParse!TypeProbe(rawLine);
			if (probe.type == "stderr")
			{
				@JSONPartial static struct RawStderr { string text; }
				auto raw = jsonParse!RawStderr(rawLine);
				ProcessStderrEvent ev;
				ev.text = raw.text;
				return [TranslatedEvent(toJson(ev), null)];
			}
			if (probe.type == "exit")
			{
				@JSONPartial static struct RawExit { int code; @JSONOptional bool is_continuation; }
				auto raw = jsonParse!RawExit(rawLine);
				ProcessExitEvent ev;
				ev.code = raw.code;
				ev.is_continuation = raw.is_continuation;
				return [TranslatedEvent(toJson(ev), null)];
			}
		}
		catch (Exception) {}
		return [TranslatedEvent(rawLine, null)];
	}

	bool isTurnResult(string rawLine)
	{
		@JSONPartial static struct TypeProbe { string type; }
		try { return jsonParse!TypeProbe(rawLine).type == "turn/result"; }
		catch (Exception) { return false; }
	}

	bool isUserMessageLine(string rawLine)
	{
		return false;
	}

	bool isAssistantMessageLine(string rawLine)
	{
		return false;
	}

	@property bool needsBash() { return true; }

	@property bool supportsFileRevert() { return false; }

	@property bool supportsDeveloperPrompt() { return false; }

	RewindResult rewindFiles(string sessionId, string afterUuid, ProcessLaunch launch)
	{
		return RewindResult(false, "File revert is not supported for Vibe sessions");
	}

	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		return [];
	}

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		return SessionMeta.init;
	}

	string matchProject(const ref DiscoveredSession session,
		const string[] knownProjectPaths)
	{
		return "";
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		import std.process : environment;
		import std.string : strip;

		auto promise = new Promise!string;
		auto vibeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);

		string[string] env = [
			"PATH": environment.get("PATH", ""),
			"HOME": environment.get("HOME", ""),
		];

		auto spec = resolveModelSpec(modelClass);
		auto args = buildVibeOneShotArgs(vibeBin, prompt, spec.model, launch);

		auto procEnv = launch.cmdPrefix is null ? env : null;

		AgentProcess proc;
		try
			proc = new AgentProcess(args, procEnv, noStdin: true,
				mode: FramingMode.raw, logName: "vibe-oneshot");
		catch (Exception e)
		{
			promise.reject(new Exception("failed to spawn vibe: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		string responseText;
		string stderrText;

		proc.onStdoutLine = (string chunk) {
			responseText ~= chunk;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			if (status != 0)
			{
				auto msg = "vibe exited with status " ~ status.to!string;
				auto details = stderrText.strip();
				if (details.length > 0)
					msg ~= ": " ~ details;
				promise.reject(new Exception(msg));
			}
			else
				promise.fulfill(responseText.strip());
		};

		void cancel() { proc.killAfterTimeout(0.seconds); }

		return OneShotHandle(promise, &cancel);
	}
}

private static string[] buildVibeOneShotArgs(string vibeBin, string prompt,
	string model, ProcessLaunch launch)
{
	string[] args = [
		vibeBin,
		"--prompt", prompt,
		"--output", "text",
		"--max-turns", "1",
		"--yolo",
	];
	// An empty alias means no explicit model; omit the flag so vibe uses its
	// own configured default.
	if (model.length > 0)
		args ~= ["--model", model];
	if (launch.cmdPrefix !is null)
		args = launch.cmdPrefix ~ args;
	return args;
}

// ---------------------------------------------------------------------------
// Private helpers — MCP server delivery via the session handshake.
// ---------------------------------------------------------------------------

private:

/// Build the CyDo MCP stdio server descriptor passed via session/new.
/// Env contract mirrors generateCopilotMcpConfig; all six entries are
/// always present (empty strings mean "not configured").
private McpServerStdio buildCydoMcpServer(int tid, SessionConfig config)
{
	import std.array : join;

	EnvVariable[] env;
	env ~= EnvVariable("CYDO_TID", to!string(tid));
	env ~= EnvVariable("CYDO_SOCKET", config.mcpSocketPath);
	env ~= EnvVariable("CYDO_CREATABLE_TYPES", config.creatableTaskTypes);
	env ~= EnvVariable("CYDO_SWITCHMODES", config.switchModes);
	env ~= EnvVariable("CYDO_HANDOFFS", config.handoffs);
	env ~= EnvVariable("CYDO_INCLUDE_TOOLS",
		config.includeTools is null ? "" : config.includeTools.join(","));

	McpServerStdio server;
	server.name = "cydo";
	server.command = cydoBinaryPath;
	server.args = ["mcp-server"];
	server.env = env;
	return server;
}

private McpServerStdio[] buildMcpServers(int tid, SessionConfig config)
{
	// S3-verified: session/new mcpServers is the delivery path for the CyDo
	// MCP server; no config.toml MCP bootstrap is needed.
	if (config.mcpSocketPath.length == 0)
		return [];
	return [buildCydoMcpServer(tid, config)];
}

private string buildNewSessionParams(int tid, string workDir, SessionConfig config)
{
	NewSessionParams params;
	params.cwd = workDir;
	params.mcpServers = buildMcpServers(tid, config);
	return toJson(params);
}

private string buildLoadSessionParams(int tid, string sessionId, string workDir,
	SessionConfig config)
{
	LoadSessionParams params;
	params.sessionId = sessionId;
	params.cwd = workDir;
	params.mcpServers = buildMcpServers(tid, config);
	return toJson(params);
}

// ---------------------------------------------------------------------------
// attachSession — spawn-side wiring, mirrors copilot.d's attachSession.
// ---------------------------------------------------------------------------

private VibeSession attachSession(VibeAcpProcess server, int tid,
	string resumeSessionId, string model, string workDir, SessionConfig config)
{
	auto session = new VibeSession(server, tid, model, workDir, config.agentName);

	// Route startup failures, stderr, and exit before the session ID is
	// adopted (new sessions learn it from the session/new response).
	server.setPendingSession(session);

	server.onReady(() {
		if (resumeSessionId.length > 0)
		{
			// The session ID is known upfront for session/load. Register
			// before sending the request: replay updates arrive before the
			// session/load response.
			session.adoptSessionId(resumeSessionId);
			server.registerSession(resumeSessionId, session);
			session.startReplay();
			server.sendRequest("session/load",
					buildLoadSessionParams(tid, resumeSessionId, workDir, config))
				.then((JsonRpcResponse resp) {
					if (resp.isError)
					{
						session.stopReplay();
						server.unregisterSession(resumeSessionId);
						server.forgetSession(session);
						ProcessStderrEvent loadErrEv;
						loadErrEv.text = "session/load error: " ~ resp.error.get.message;
						session.emitEvent(toJson(loadErrEv));
						session.handleStartupFailure(new Exception(
							"session/load error: " ~ resp.error.get.message));
						return;
					}
					session.onSessionStarted();
				}, (Exception e) {
					session.stopReplay();
					server.unregisterSession(resumeSessionId);
					server.forgetSession(session);
					session.handleStartupFailure(e);
				});
		}
		else
		{
			server.sendRequest("session/new",
					buildNewSessionParams(tid, workDir, config))
				.then((JsonRpcResponse resp) {
					if (resp.isError)
					{
						server.forgetSession(session);
						session.handleStartupFailure(new Exception(
							"session/new error: " ~ resp.error.get.message));
						return;
					}
					string sessionId;
					try
					{
						auto nsr = resp.result.deserializeTo!NewSessionResponse();
						sessionId = nsr.sessionId;
					}
					catch (Exception) {}
					if (sessionId.length == 0)
					{
						server.forgetSession(session);
						session.handleStartupFailure(new Exception(
							"session/new response has no session ID"));
						return;
					}
					session.adoptSessionId(sessionId);
					server.registerSession(sessionId, session);
					session.onSessionStarted();
				}, (Exception e) {
					server.forgetSession(session);
					session.handleStartupFailure(e);
				});
		}
	});

	return session;
}

// ---------------------------------------------------------------------------
// VibeSession — one vibe-acp session, implementing AgentSession +
// VibeSessionHandler. Submission rides the session/prompt request; its
// response is both the acceptance and the turn boundary.
// ---------------------------------------------------------------------------

class VibeSession : AgentSession, VibeSessionHandler
{
	private VibeAcpProcess server;
	private int tid;
	private string sessionId_;
	private string model;
	private string workDir;
	private string agentName_;
	private bool alive_;
	private bool turnInProgress;
	private bool replayMode; // true during session/load replay
	private bool gracefulShutdown_; // true after closeStdin() — handleExit reports 0
	private bool forcedStop_;       // true after stop() — handleExit always reports 1

	// Streaming state: item tracking for item-based protocol.
	private int nextItemIndex;
	private int turnNamespaceCounter_;

	// Active streaming item for text/thinking, keyed by the vibe messageId.
	private struct ActiveTextItem
	{
		string id;         // item_id
		string type;       // "text" or "thinking"
		string text;       // accumulated content
		string sourceKey;  // vibe ContentChunk messageId
	}
	private ActiveTextItem activeTextItem;
	private string activeTurnNamespace_;

	// In-flight tool calls (parallel — multiple may be active simultaneously).
	private struct ToolItem
	{
		string id;    // item_id ("vb-tool-<toolCallId>")
		string name;  // canonical tool name
		string input; // tool input JSON
		bool inputEmitted; // rawInput already emitted as input_json_delta
	}
	private ToolItem[string] activeTools; // keyed by toolCallId

	private string lastResultText; // last completed text content, for turn/result

	// Raw/timestamp plumbing for the update currently being translated.
	private string currentRawJson_;

	private bool sessionReady_; // true after session/new|load response

	// Each message owns its settlement while it waits for readiness, a turn,
	// or the correlated session/prompt response.
	private static final class PendingMessage
	{
		ContentBlock[] content;
		string text;
		string correlationId;
		bool isContextBootstrap;
		Promise!AgentSubmissionReceipt promise;
		bool settled;
		bool accepted;
		TranslatedEvent gatedUserEcho;
		bool hasGatedUserEcho;

		this(const(ContentBlock)[] content, string text, string correlationId,
			bool isContextBootstrap)
		{
			this.content = content.dup;
			this.text = text;
			this.correlationId = correlationId;
			this.isContextBootstrap = isContextBootstrap;
			this.promise = new Promise!AgentSubmissionReceipt;
		}
	}
	private PendingMessage[] pendingMessages;

	// The native user echo arrives as user_message_chunk(s); accumulate them
	// against the originating send until the expected content is complete.
	private static final class ExpectedUserMessage
	{
		string content;     // expected text from the originating send
		string accumulated; // chunk text received so far
		bool done;
		PendingMessage submission;

		this(PendingMessage submission)
		{
			this.content = submission.text;
			this.submission = submission;
		}
	}
	private ExpectedUserMessage[] expectedUserMessages;

	// Callbacks
	package void delegate(TranslatedEvent) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;
	private void delegate(string sessionId) nativeSessionStartedHandler_;
	private bool nativeSessionStartedNotified_;

	this(VibeAcpProcess server, int tid, string model, string workDir,
		string agentName = null)
	{
		this.server = server;
		this.tid = tid;
		this.model = model;
		this.workDir = workDir;
		this.agentName_ = agentName;
		this.alive_ = true;
	}

	/// Adopt the server-assigned session ID (from session/new, or the
	/// resume ID for session/load).
	package void adoptSessionId(string sessionId)
	{
		sessionId_ = sessionId;
	}

	/// Called to suppress duplicate translation during session/load replay.
	package void startReplay()
	{
		replayMode = true;
		activeTurnNamespace_ = "replay";
	}

	package void stopReplay()
	{
		replayMode = false;
	}

	/// Called when the session/new or session/load response arrives.
	package void onSessionStarted()
	{
		replayMode = false;
		turnInProgress = false;
		sessionReady_ = true;

		// Emit synthetic session/init after publishing the native ID.
		notifyNativeSessionStarted();
		SessionInitEvent initEv;
		initEv.session_id      = sessionId_;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "vibe";
		initEv.agent_name      = agentName_;
		initEv.supports_file_revert = false;

		emitEvent(toJson(initEv));

		// Drain queued messages now that the session is ready.
		drainPendingMessages();
	}

	private void rejectSubmission(PendingMessage submission, Exception error)
	{
		if (submission.settled)
			return;
		submission.settled = true;
		submission.promise.reject(error);
	}

	private void removeExpectedUserMessage(PendingMessage submission)
	{
		foreach (i, expected; expectedUserMessages)
			if (expected.submission is submission)
			{
				expectedUserMessages = expectedUserMessages[0 .. i]
					~ expectedUserMessages[i + 1 .. $];
				return;
			}
		assert(false, "Vibe submission response has no expected user echo");
	}

	private void emitAcceptedUserEcho(PendingMessage submission,
		TranslatedEvent event)
	{
		assert(submission.accepted,
			"Vibe user_message_chunk emitted before session/prompt acceptance");
		auto output = outputHandler_;
		// Queue after fulfillment so App commits acceptance before translating it.
		onNextTick(socketManager, {
			if (output)
				output(event);
		});
	}

	private void releaseGatedUserEcho(PendingMessage submission)
	{
		if (!submission.hasGatedUserEcho)
			return;
		auto event = submission.gatedUserEcho;
		submission.gatedUserEcho = TranslatedEvent.init;
		submission.hasGatedUserEcho = false;
		removeExpectedUserMessage(submission);
		emitAcceptedUserEcho(submission, event);
	}

	private void rejectUnsettledMessages(Exception error)
	{
		auto queued = pendingMessages;
		pendingMessages = null;
		foreach (submission; queued)
			rejectSubmission(submission, error);

		auto expected = expectedUserMessages;
		expectedUserMessages = null;
		foreach (message; expected)
			rejectSubmission(message.submission, error);
	}

	private void resetRejectedSubmission()
	{
		turnInProgress = false;
		nextItemIndex = 0;
		activeTextItem = ActiveTextItem.init;
		activeTools = null;
		lastResultText = null;
	}

	private void drainPendingMessages()
	{
		if (!alive_ || !sessionReady_ || turnInProgress
			|| pendingMessages.length == 0)
			return;
		auto submission = pendingMessages[0];
		pendingMessages = pendingMessages[1 .. $];
		submitMessage(submission);
	}

	private void submitMessage(PendingMessage submission)
	{
		assert(sessionReady_ && !turnInProgress,
			"Vibe submission requires a ready idle session");
		turnInProgress = true;
		nextItemIndex = 0;
		activeTextItem = ActiveTextItem.init;
		activeTools = null;
		lastResultText = null;
		activeTurnNamespace_ = to!string(++turnNamespaceCounter_);
		expectedUserMessages ~= new ExpectedUserMessage(submission);

		PromptParams params;
		params.sessionId = sessionId_;
		foreach (ref block; submission.content)
		{
			if (block.type != "text")
				continue;
			VibePromptBlock promptBlock;
			promptBlock.text = block.text;
			params.prompt ~= promptBlock;
		}
		try
		{
			server.sendRequest("session/prompt", toJson(params))
				.then((JsonRpcResponse response) {
					if (submission.settled)
						return;
					if (response.isError)
					{
						removeExpectedUserMessage(submission);
						resetRejectedSubmission();
						rejectSubmission(submission,
							new Exception(response.error.get.message));
						drainPendingMessages();
						return;
					}
					// The response is both the acceptance and the turn
					// boundary: finalize streaming state, close the turn,
					// then release the gated user echo.
					finalizeActiveTextItem();
					finalizeAllTools();
					emitTurnStop();
					turnInProgress = false;
					submission.accepted = true;
					submission.settled = true;
					submission.promise.fulfill(
						AgentSubmissionReceipt.appServerAccepted);
					releaseGatedUserEcho(submission);
					emitTurnResult(response);
					drainPendingMessages();
				}, (Exception e) {
					if (submission.settled)
						return;
					removeExpectedUserMessage(submission);
					resetRejectedSubmission();
					rejectSubmission(submission, e);
					drainPendingMessages();
				}).ignoreResult();
		}
		catch (Exception e)
		{
			removeExpectedUserMessage(submission);
			resetRejectedSubmission();
			rejectSubmission(submission, e);
			drainPendingMessages();
		}
	}

	// ----- AgentSession interface -----

	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content,
		string correlationId = null, bool isContextBootstrap = false)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Vibe: " ~ b.type);
		}

		auto submission = new PendingMessage(content, text, correlationId,
			isContextBootstrap);
		if (!alive_)
		{
			submission.promise.reject(new Exception(
				"Vibe session is no longer alive"));
			return submission.promise;
		}

		if (!sessionReady_ || turnInProgress)
			pendingMessages ~= submission;
		else
			submitMessage(submission);
		return submission.promise;
	}

	void invalidatePendingSubmittedMessages()
	{
		rejectUnsettledMessages(new Exception(
			"Vibe message submission was invalidated"));
	}

	@property bool supportsImages() const { return false; }

	void interrupt()
	{
		if (!alive_ || sessionId_.length == 0)
			return;
		CancelParams params;
		params.sessionId = sessionId_;
		// ACP: session/cancel is a notification; the in-flight session/prompt
		// must return stopReason "cancelled".
		server.sendNotification("session/cancel", toJson(params));
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive_)
			return;
		rejectUnsettledMessages(new Exception(
			"Vibe session closed before accepting message submission"));
		if (sessionId_.length > 0)
			interrupt();
		alive_ = false;
		forcedStop_ = true;
		server.shutdown();
	}

	void closeStdin()
	{
		rejectUnsettledMessages(new Exception(
			"Vibe session closed before accepting message submission"));
		if (!alive_)
			return;
		if (sessionId_.length > 0)
			interrupt();
		alive_ = false;
		gracefulShutdown_ = true;
		server.shutdown();
	}

	void killAfterTimeout(Duration timeout) {} // no-op: server.shutdown handles graceful exit

	@property bool canStopAfterCloseStdin() const
	{
		return false;
	}

	@property void onNativeSessionStarted(void delegate(string sessionId) callback)
	{
		nativeSessionStartedHandler_ = callback;
		if (nativeSessionStartedHandler_ && sessionId_.length > 0)
		{
			nativeSessionStartedNotified_ = true;
			nativeSessionStartedHandler_(sessionId_);
		}
	}

	private void notifyNativeSessionStarted()
	{
		if (nativeSessionStartedNotified_)
			return;
		nativeSessionStartedNotified_ = true;
		if (nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(sessionId_);
	}

	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && (server is null || !server.dead); }

	// ----- VibeSessionHandler interface -----

	void handleSessionUpdate(SessionUpdateParams params)
	{
		if (!alive_)
			return;
		currentRawJson_ = params.update.toJson();
		VibeSessionUpdate update;
		try update = params.update.deserializeTo!VibeSessionUpdate();
		catch (Exception)
		{
			emitEvent(makeUnrecognizedEvent("malformed vibe session update"),
				currentRawJson_);
			return;
		}
		switch (update.sessionUpdate)
		{
			case "user_message_chunk":
				handleUserMessageChunk(update);
				break;
			case "agent_message_chunk":
				handleAgentChunk(update, "text");
				break;
			case "agent_thought_chunk":
				handleAgentChunk(update, "thinking");
				break;
			case "tool_call":
				handleToolCall(update);
				break;
			case "tool_call_update":
				handleToolCallUpdate(update);
				break;
			case "plan":
			case "available_commands_update":
			case "current_mode_update":
			case "config_option_update":
			case "session_info_update":
			case "usage_update":
				break;
			default:
				emitEvent(makeUnrecognizedEvent(
					"unknown vibe update: " ~ update.sessionUpdate), currentRawJson_);
				break;
		}
	}

	Promise!PermissionOutcome handlePermissionRequest(PermissionRequestParams params)
	{
		// Auto-approve all permission requests with allow_once (the CyDo
		// permission UX rides its own MCP tools, not ACP permissions).
		return resolve(PermissionOutcome.allowOnce());
	}

	void handleStderr(string line)
	{
		if (stderrHandler_)
			stderrHandler_(line);
	}

	void handleStartupFailure(Exception error)
	{
		rejectUnsettledMessages(error);
		handleExit(1);
	}

	void handleExit(int status)
	{
		rejectUnsettledMessages(new Exception(
			"Vibe session exited before accepting message submission"));
		alive_ = false;
		if (exitHandler_ is null)
			return;
		auto cb = exitHandler_;
		exitHandler_ = null;
		int code = gracefulShutdown_ ? 0 : (forcedStop_ ? 1 : status);
		cb(code);
	}

	// ----- Update handlers -----

	private void emitEvent(string translated, string rawJson = null)
	{
		if (outputHandler_)
			outputHandler_(TranslatedEvent(translated,
				rawJson.length > 0 ? rawJson : null));
	}

	private void handleUserMessageChunk(VibeSessionUpdate update)
	{
		auto text = chunkText(update.content);
		if (replayMode)
		{
			ContentBlock cb;
			cb.type = "text";
			cb.text = text;
			ItemStartedEvent replayEv;
			replayEv.item_id = "vb-user-" ~ (update.messageId.length > 0
				? update.messageId
				: activeTurnNamespace_ ~ "-" ~ to!string(nextItemIndex++));
			replayEv.item_type = "user_message";
			replayEv.content = [cb];
			replayEv.is_replay = true;
			if (update.messageId.length > 0)
				replayEv.uuid = update.messageId;
			emitEvent(toJson(replayEv), currentRawJson_);
			return;
		}

		assert(expectedUserMessages.length > 0,
			"Vibe user_message_chunk has no queued originating send");
		auto expected = expectedUserMessages[0];
		if (expected.done)
			return;
		expected.accumulated ~= text;
		bool diverged = expected.accumulated.length > expected.content.length
			|| expected.content[0 .. expected.accumulated.length] != expected.accumulated;
		if (!diverged && expected.accumulated.length < expected.content.length)
			return; // wait for the remaining echo chunks
		// The echo is complete (or diverged): complete with the expected
		// content so the UI shows what CyDo actually submitted.
		expected.done = true;
		if (diverged)
			emitEvent(makeUnrecognizedEvent(
				"vibe user_message_chunk diverged from its originating send"),
				currentRawJson_);
		auto translated = buildUserEcho(expected.submission, expected.content,
			update.messageId);
		if (expected.submission.accepted)
		{
			expectedUserMessages = expectedUserMessages[1 .. $];
			emitAcceptedUserEcho(expected.submission, translated);
		}
		else
		{
			expected.submission.gatedUserEcho = translated;
			expected.submission.hasGatedUserEcho = true;
		}
	}

	private TranslatedEvent buildUserEcho(PendingMessage submission, string text,
		string messageId)
	{
		ContentBlock cb;
		cb.type = "text";
		cb.text = text;
		ItemStartedEvent userEv;
		userEv.item_id = "vb-user-" ~ (messageId.length > 0 ? messageId
			: activeTurnNamespace_ ~ "-" ~ to!string(nextItemIndex++));
		userEv.item_type = "user_message";
		userEv.content = [cb];
		if (messageId.length > 0)
			userEv.uuid = messageId;
		userEv.correlation_id = submission.correlationId;
		auto translated = TranslatedEvent(toJson(userEv), currentRawJson_);
		translated.isContextBootstrap = submission.isContextBootstrap;
		return translated;
	}

	private void handleAgentChunk(VibeSessionUpdate update, string itemType)
	{
		auto text = chunkText(update.content);
		if (activeTextItem.type != itemType
			|| activeTextItem.sourceKey != update.messageId)
		{
			finalizeActiveTextItem();
			assert(activeTurnNamespace_.length > 0,
				"Vibe chunk has no active turn namespace");
			auto id = (itemType == "text" ? "vb-text-" : "vb-think-")
				~ activeTurnNamespace_ ~ "-" ~ to!string(nextItemIndex++);
			activeTextItem = ActiveTextItem(id, itemType, "", update.messageId);
			ItemStartedEvent startEv;
			startEv.item_id   = id;
			startEv.item_type = itemType;
			emitEvent(toJson(startEv), currentRawJson_);
		}

		activeTextItem.text ~= text;

		if (text.length > 0)
		{
			ItemDeltaEvent deltaEv;
			deltaEv.item_id    = activeTextItem.id;
			deltaEv.delta_type = itemType == "text" ? "text_delta" : "thinking_delta";
			deltaEv.content    = text;
			emitEvent(toJson(deltaEv), currentRawJson_);
		}
	}

	private void handleToolCall(VibeSessionUpdate update)
	{
		// Resume markers replay as a synthetic completed tool call pair —
		// consume silently.
		if (update.toolCallId.startsWith("checkpoint:resume:"))
			return;
		// Compaction surfaces as a think tool_call pair with
		// _meta.checkpoint_kind "compaction" — consume both halves; one
		// session/compacted is emitted at completion (never match titles).
		if (parseVibeMeta(update.meta).checkpointKind == "compaction")
			return;

		finalizeActiveTextItem();

		auto meta = parseVibeMeta(update.meta);
		auto toolName = meta.toolName.length > 0 ? meta.toolName : "unknown";
		string name = toolName;
		string toolServer;
		string toolSource;
		if (toolName.startsWith("cydo_"))
		{
			toolServer = "cydo";
			toolSource = "mcp";
			name = toolName[5 .. $];
		}
		auto inputJson = update.rawInput.json !is null && update.rawInput.json.length > 0
			? update.rawInput.json : "{}";

		auto id = "vb-tool-" ~ update.toolCallId;
		ToolItem tool = ToolItem(id, name, inputJson, inputJson != "{}");
		activeTools[update.toolCallId] = tool;

		ItemStartedEvent toolStartEv;
		toolStartEv.item_id   = id;
		toolStartEv.item_type = "tool_use";
		toolStartEv.name      = name;
		if (toolServer.length > 0)
		{
			toolStartEv.tool_server = toolServer;
			toolStartEv.tool_source = toolSource;
		}
		toolStartEv.input = JSONFragment(inputJson);
		emitEvent(toJson(toolStartEv), currentRawJson_);

		// Emit the full input as a single input_json_delta so the UI can
		// display it during streaming.
		if (tool.inputEmitted)
		{
			ItemDeltaEvent inputDeltaEv;
			inputDeltaEv.item_id    = id;
			inputDeltaEv.delta_type = "input_json_delta";
			inputDeltaEv.content    = inputJson;
			emitEvent(toJson(inputDeltaEv), currentRawJson_);
		}
	}

	private void handleToolCallUpdate(VibeSessionUpdate update)
	{
		if (update.toolCallId.startsWith("checkpoint:resume:"))
			return;
		if (parseVibeMeta(update.meta).checkpointKind == "compaction")
		{
			if (update.status == "completed")
			{
				SessionCompactedEvent compactedEv;
				emitEvent(toJson(compactedEv), currentRawJson_);
			}
			return;
		}

		auto p = update.toolCallId in activeTools;
		if (p is null)
			return;

		// The tool_call start may arrive without rawInput; the first
		// progress update carrying it emits the input then.
		if (update.rawInput.json.length > 0 && !p.inputEmitted)
		{
			p.input = update.rawInput.json;
			p.inputEmitted = true;
			ItemDeltaEvent inputDeltaEv;
			inputDeltaEv.item_id    = p.id;
			inputDeltaEv.delta_type = "input_json_delta";
			inputDeltaEv.content    = p.input;
			emitEvent(toJson(inputDeltaEv), currentRawJson_);
		}

		if (update.status == "completed" || update.status == "failed")
		{
			finalizeTool(*p, update, update.status == "failed");
			activeTools.remove(update.toolCallId);
		}
	}

	private void finalizeTool(ref ToolItem tool, VibeSessionUpdate update,
		bool failed)
	{
		auto resultText = extractToolResultText(update.content, update.rawOutput);

		ItemCompletedEvent toolCompEv;
		toolCompEv.item_id = tool.id;
		toolCompEv.input   = JSONFragment(tool.input.length > 0 ? tool.input : `{}`);
		emitEvent(toJson(toolCompEv), currentRawJson_);

		ItemResultEvent toolResEv;
		toolResEv.item_id = tool.id;
		if (contentHasDiff(update.content))
			toolResEv.content = JSONFragment(update.content.json); // diff blocks preserved verbatim
		else
			toolResEv.content = JSONFragment(toJson(resultText));
		toolResEv.is_error = failed;
		emitEvent(toJson(toolResEv), currentRawJson_);
	}

	// ----- Turn completion -----

	private void emitTurnStop()
	{
		TurnStopEvent tsEv;
		tsEv.model = model;
		emitEvent(toJson(tsEv), currentRawJson_);
	}

	private void emitTurnResult(JsonRpcResponse response)
	{
		PromptResponse promptResponse;
		try promptResponse = response.result.deserializeTo!PromptResponse();
		catch (Exception) {}

		TurnResultEvent trEv;
		trEv.subtype        = "success";
		trEv.is_error       = false;
		trEv.num_turns      = 1;
		trEv.duration_ms    = 0;
		trEv.total_cost_usd = 0.0;
		trEv.result         = lastResultText;
		trEv.usage          = UsageInfo(promptResponse.usage.input_tokens,
			promptResponse.usage.output_tokens);
		emitEvent(toJson(trEv), currentRawJson_);
		lastResultText = null;
	}

	/// Finalize the active text/thinking item: emit item/completed.
	/// No-op if there is no active text item.
	private void finalizeActiveTextItem()
	{
		if (activeTextItem.type.length == 0)
			return;

		if (activeTextItem.type == "text")
			lastResultText = activeTextItem.text;
		ItemCompletedEvent finTextEv;
		finTextEv.item_id = activeTextItem.id;
		finTextEv.text    = activeTextItem.text;
		emitEvent(toJson(finTextEv), currentRawJson_);

		activeTextItem = ActiveTextItem.init;
	}

	/// Finalize all remaining in-flight tools (at turn end).
	private void finalizeAllTools()
	{
		foreach (ref tool; activeTools)
		{
			ItemCompletedEvent finToolEv;
			finToolEv.item_id = tool.id;
			finToolEv.input   = JSONFragment(tool.input.length > 0 ? tool.input : `{}`);
			emitEvent(toJson(finToolEv), currentRawJson_);
			ItemResultEvent finResEv;
			finResEv.item_id = tool.id;
			finResEv.content = JSONFragment(toJson(""));
			emitEvent(toJson(finResEv), currentRawJson_);
		}
		activeTools = null;
	}
}

// ---------------------------------------------------------------------------
// Private translation helpers
// ---------------------------------------------------------------------------

private struct VibeToolMeta
{
	string toolName;
	string checkpointKind;
}

/// Parse the vibe-specific `_meta` object of a tool_call update
/// (`tool_name`, `checkpoint_kind`).
private VibeToolMeta parseVibeMeta(JSONFragment meta)
{
	VibeToolMeta result;
	if (meta.json.length == 0)
		return result;
	@JSONPartial static struct MetaProbe
	{
		@JSONName("tool_name") string toolName;
		@JSONName("checkpoint_kind") string checkpointKind;
	}
	try
	{
		auto probe = jsonParse!MetaProbe(meta.json);
		result.toolName = probe.toolName;
		result.checkpointKind = probe.checkpointKind;
	}
	catch (Exception) {}
	return result;
}

/// Extract the text of an ACP ContentChunk block.
private string chunkText(JSONFragment content)
{
	if (content.json.length == 0)
		return "";
	@JSONPartial static struct ChunkProbe { string type; string text; }
	try
	{
		return jsonParse!ChunkProbe(content.json).text;
	}
	catch (Exception)
	{
		return "";
	}
}

/// Extract plain text from a completed tool call: the `content` array's
/// text blocks, falling back to `rawOutput` (plain string, then
/// content/detailedContent/stdout fields).
private string extractToolResultText(JSONFragment content, JSONFragment rawOutput)
{
	if (content.json.length > 0)
	{
		try
		{
			@JSONPartial static struct ContentEntry
			{
				string type;
				@JSONPartial static struct Inner { string type; string text; }
				Inner content;
			}
			auto entries = jsonParse!(ContentEntry[])(content.json);
			string result;
			foreach (ref entry; entries)
			{
				if (entry.type == "content" && entry.content.text.length > 0)
				{
					if (result.length > 0) result ~= "\n";
					result ~= entry.content.text;
				}
			}
			if (result.length > 0)
				return result;
		}
		catch (Exception) {}
	}
	if (rawOutput.json.length == 0)
		return "";
	// Plain string result.
	try return jsonParse!string(rawOutput.json);
	catch (Exception) {}
	@JSONPartial static struct OutputProbe
	{
		string content;
		string detailedContent;
		string stdout;
	}
	try
	{
		auto obj = jsonParse!OutputProbe(rawOutput.json);
		if (obj.content.length > 0)
			return obj.content;
		if (obj.detailedContent.length > 0)
			return obj.detailedContent;
		if (obj.stdout.length > 0)
			return obj.stdout;
	}
	catch (Exception) {}
	return "";
}

/// Whether a tool call content array contains diff blocks (preserved
/// verbatim in item/result).
private bool contentHasDiff(JSONFragment content)
{
	if (content.json.length == 0)
		return false;
	try
	{
		@JSONPartial static struct EntryProbe { string type; }
		auto entries = jsonParse!(EntryProbe[])(content.json);
		foreach (ref entry; entries)
			if (entry.type == "diff")
				return true;
	}
	catch (Exception) {}
	return false;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

version (unittest) private final class TestVibeConnection : IConnection
{
	string[] sentMessages;
	private ReadDataHandler readDataHandler;

	@property ConnectionState state()
	{
		return ConnectionState.connected;
	}

	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		ubyte[] message;
		foreach (ref datum; data)
			datum.enter((contents) { message ~= cast(ubyte[]) contents; });
		sentMessages ~= cast(string) message;
	}
	alias send = IConnection.send;

	JsonRpcRequest takeRequest(string expectedMethod)
	{
		assert(sentMessages.length > 0,
			"Vibe test connection has no pending request");
		auto request = jsonParse!JsonRpcRequest(sentMessages[0]);
		sentMessages = sentMessages[1 .. $];
		assert(request.method == expectedMethod,
			"Unexpected Vibe request method: " ~ request.method);
		assert(request.id, "Vibe request has no JSON-RPC id");
		return request;
	}

	JsonRpcRequest takeNotification(string expectedMethod)
	{
		assert(sentMessages.length > 0,
			"Vibe test connection has no pending notification");
		auto request = jsonParse!JsonRpcRequest(sentMessages[0]);
		sentMessages = sentMessages[1 .. $];
		assert(request.method == expectedMethod,
			"Unexpected Vibe notification method: " ~ request.method);
		assert(request.isNotification, "Vibe notification has a JSON-RPC id");
		return request;
	}

	void respond(JsonRpcRequest request, JsonRpcResponse response)
	{
		import ae.utils.array : asBytes;

		assert(readDataHandler !is null,
			"Vibe test connection has no response handler");
		response.id = request.id;
		readDataHandler(Data(toJson(response).asBytes));
	}

	void receive(string message)
	{
		import ae.utils.array : asBytes;

		assert(readDataHandler !is null,
			"Vibe test connection has no response handler");
		readDataHandler(Data(message.asBytes));
	}

	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		assert(false, reason);
	}
	@property void handleConnect(ConnectHandler value) {}
	@property void handleReadData(ReadDataHandler value) { readDataHandler = value; }
	@property void handleDisconnect(DisconnectHandler value) {}
	@property void handleBufferFlushed(BufferFlushedHandler value) {}
}

version (unittest) private final class TestVibeSubmissionOutcome
{
	int acceptedCount;
	int rejectedCount;
	string rejectionMessage;

	this(Promise!AgentSubmissionReceipt promise)
	{
		promise.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			acceptedCount++;
		}, (Exception error) {
			rejectedCount++;
			rejectionMessage = error.msg;
		}).ignoreResult();
	}
}

version (unittest) private void drainVibePromiseNextTicks()
{
	for (;;)
	{
		auto handlers = __traits(getMember, socketManager,
			"nextTickHandlers");
		if (handlers.length == 0)
			return;
		mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
		foreach (handler; handlers)
			handler();
	}
}

version (unittest) private JsonRpcResponse acceptedVibeResponse(
	string resultJson = `{}`)
{
	JsonRpcResponse response;
	response.result = jsonParse!(typeof(response.result))(resultJson);
	return response;
}

version (unittest) private JsonRpcResponse rejectedVibeResponse(string message)
{
	JsonRpcResponse response;
	response.error = JsonRpcError.fromCode(
		JsonRpcErrorCode.invalidRequest, message);
	return response;
}

version (unittest) private void assertVibePending(TestVibeSubmissionOutcome outcome)
{
	assert(outcome.acceptedCount == 0 && outcome.rejectedCount == 0);
}

version (unittest) private void assertVibeAcceptedOnce(
	TestVibeSubmissionOutcome outcome)
{
	assert(outcome.acceptedCount == 1 && outcome.rejectedCount == 0);
}

version (unittest) private void assertVibeRejectedOnce(
	TestVibeSubmissionOutcome outcome, string expectedMessage = null)
{
	assert(outcome.acceptedCount == 0 && outcome.rejectedCount == 1);
	assert(outcome.rejectionMessage.length > 0);
	if (expectedMessage.length > 0)
		assert(outcome.rejectionMessage == expectedMessage);
}

version (unittest) private string vibeUpdate(string sessionId, string updateJson)
{
	return `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"`
		~ sessionId ~ `","update":` ~ updateJson ~ `}}`;
}

version (unittest) private struct ReadyVibeFixture
{
	TestVibeConnection connection;
	VibeAcpProcess server;
	VibeSession session;
}

version (unittest) private ReadyVibeFixture makeReadyVibeSession(int tid,
	string nativeSessionId = null)
{
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, tid, null, "test-model",
		"/test/workdir", SessionConfig.init);
	auto newRequest = connection.takeRequest("session/new");
	auto sessionId = nativeSessionId.length > 0
		? nativeSessionId : "native-vibe-" ~ to!string(tid);
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"` ~ sessionId ~ `"}`));
	drainVibePromiseNextTicks();
	return ReadyVibeFixture(connection, server, session);
}

unittest
{
	auto agent = new VibeAgent;

	// With no overrides, hardcoded defaults apply.
	assert(agent.resolveModelSpec("small")
		== ModelSpec(ModelSpecFields("devstral-small")));
	assert(agent.resolveModelSpec("medium")
		== ModelSpec(ModelSpecFields("mistral-medium-3.5")));
	assert(agent.resolveModelSpec("large")
		== ModelSpec(ModelSpecFields("mistral-medium-3.5")));

	// An override replaces the default model.
	agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
	assert(agent.resolveModelSpec("large").model == "custom-model");

	// An effort-only override keeps the driver's default model.
	agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
	auto effortOnly = agent.resolveModelSpec("large");
	assert(effortOnly.model == "mistral-medium-3.5");
	assert(effortOnly.effort == "high");

	// An unknown class passes through, and can still be overridden.
	agent.setModelAliases(null);
	auto passthrough = agent.resolveModelSpec("best");
	assert(passthrough.model == "best");
	assert(passthrough.effort == "");
	agent.setModelAliases(["best": ModelSpec(ModelSpecFields("opus", "max"))]);
	auto customClass = agent.resolveModelSpec("best");
	assert(customClass.model == "opus");
	assert(customClass.effort == "max");

	// The empty-class edge stays inert.
	agent.setModelAliases(null);
	assert(agent.resolveModelSpec("").model == "");

	// Interrupted tool call repair is inert in Part 2.
	assert(agent.repairInterruptedToolCall([`{"type":"tool.execution_complete"}`],
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

unittest
{
	ProcessLaunch launch;
	auto args = buildVibeOneShotArgs("vibe-acp", "hello", "mistral-medium-3.5",
		launch);
	assert(args == [
		"vibe-acp", "--prompt", "hello", "--output", "text",
		"--max-turns", "1", "--yolo", "--model", "mistral-medium-3.5",
	]);
	auto noModel = buildVibeOneShotArgs("vibe-acp", "hello", "", launch);
	assert(noModel == [
		"vibe-acp", "--prompt", "hello", "--output", "text",
		"--max-turns", "1", "--yolo",
	]);
	launch.cmdPrefix = ["bwrap"];
	auto prefixed = buildVibeOneShotArgs("vibe-acp", "hello", "", launch);
	assert(prefixed == [
		"bwrap", "vibe-acp", "--prompt", "hello", "--output", "text",
		"--max-turns", "1", "--yolo",
	]);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath, dirName;
	import std.process : environment, execute;
	import cydo.runtime.config : PathMode, SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	auto root = buildPath(tempDir(), "cydo-vibe-configure-sandbox");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto environmentKeys = ["HOME", "PATH", "VIBE_HOME", "MISTRAL_API_KEY",
		"HTTPS_PROXY", "NO_PROXY"];
	string[string] previousEnvironment;
	bool[string] hadEnvironment;
	foreach (key; environmentKeys)
	{
		hadEnvironment[key] = key in environment;
		previousEnvironment[key] = environment.get(key, "");
	}
	scope (exit)
	{
		foreach (key; environmentKeys)
		{
			if (hadEnvironment[key])
				environment[key] = previousEnvironment[key];
			else
				environment.remove(key);
		}
	}

	auto home = buildPath(root, "home");
	auto vibeHome = buildPath(home, "configured-vibe-home");
	auto executableDir = buildPath(root, "bin");
	auto executable = buildPath(executableDir, "vibe-acp");
	mkdirRecurse(vibeHome);
	mkdirRecurse(executableDir);
	write(executable, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", executable]);
	environment["HOME"] = home;
	environment["VIBE_HOME"] = vibeHome;
	environment["MISTRAL_API_KEY"] = "test-mistral-key";
	environment["HTTPS_PROXY"] = "http://vibe.test.invalid:8080";
	environment["NO_PROXY"] = "localhost";
	environment["PATH"] = executableDir;

	auto agent = new VibeAgent;
	auto cydoDir = cydoBinaryDir();
	assert(cydoDir.length > 0);

	SandboxConfig global;
	global.paths = [
		executableDir: PathMode.rw,
		cydoDir: PathMode.always_rw,
	];
	global.env = [
		"CYDO_VIBE_BIN": executable,
		"PATH": executableDir,
	];
	auto executableMounts = executableMountPaths(
		resolveExecutablePath(executable, global.env));
	assert(executableMounts.length == 1);
	assert(executableMounts[0] == executableDir);
	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths,
		ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.agentName = "vibe";
	agentSandbox.workspaceName = "test";
	auto resolved = resolveSandbox(global, SandboxConfig.init, SandboxConfig.init,
		agentSandbox, "");

	auto executableView = resolved.paths.exact(executableDir).get;
	assert(executableView.declaration.get.mode == PathMode.rw);
	assert(executableView.effectiveMode == PathMode.rw);
	auto cydoView = resolved.paths.exact(cydoDir).get;
	assert(cydoView.declaration.get.mode == PathMode.always_rw);
	assert(cydoView.effectiveMode == PathMode.always_rw);

	// Vibe differs from Copilot: VIBE_HOME is passed through to the child
	// environment, but the profile root is not mounted by configureSandbox —
	// native history is materialized by prepareProcessLaunch.
	assert(resolved.env["VIBE_HOME"] == vibeHome);
	assert(resolved.paths.exact(vibeHome).isNull);
	auto nativeRule = agent.nativeHistoryRule;
	assert(nativeRule.driver == AgentDriver.vibe);
	assert(nativeRule.profileEnvName == "VIBE_HOME");
	assert(nativeRule.homeRelativeDefault == ".vibe");
	assert(nativeRule.homeSupportRequirements.length == 0);
	assert(resolved.env["PATH"] == executableDir);
	assert(resolved.env["MISTRAL_API_KEY"] == "test-mistral-key");
	assert(resolved.env["HTTPS_PROXY"] == "http://vibe.test.invalid:8080");
	assert(resolved.env["NO_PROXY"] == "localhost");

	// A configured profile selector stays in the resolved child environment
	// (the passthrough must not clobber an explicit launch value).
	auto configuredVibeHome = buildPath(home, "sandbox-vibe-home");
	SandboxConfig configuredGlobal;
	configuredGlobal.env = [
		"CYDO_VIBE_BIN": executable,
		"PATH": executableDir,
		"VIBE_HOME": configuredVibeHome,
	];
	auto configuredResolved = resolveSandbox(configuredGlobal, SandboxConfig.init,
		SandboxConfig.init, agentSandbox, "");
	assert(configuredResolved.paths.exact(configuredVibeHome).isNull);
	assert(configuredResolved.paths.exact(vibeHome).isNull);
	assert(configuredResolved.env["VIBE_HOME"] == configuredVibeHome);

	// Missing launch values inherit the host credentials via passthrough only.
	SandboxPaths defaultPaths;
	string[string] defaultEnv = ["CYDO_VIBE_BIN": executable];
	agent.configureSandbox(defaultPaths, defaultEnv);
	assert(defaultEnv["PATH"] == executableDir);
	assert(defaultEnv["VIBE_HOME"] == vibeHome);
	assert(defaultEnv["MISTRAL_API_KEY"] == "test-mistral-key");
	assert(defaultEnv["HTTPS_PROXY"] == "http://vibe.test.invalid:8080");
	assert(defaultEnv["NO_PROXY"] == "localhost");
	assert(defaultPaths.exact(vibeHome).isNull);
	foreach (path; executableMounts)
		assert(defaultPaths.exact(path).get.effectiveMode == PathMode.ro);

	// Writable ancestors satisfy read visibility without producing a child mount.
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"vibe test", "pre-existing host access");
	SandboxPaths ancestorPaths;
	auto executableParent = dirName(executableDir);
	auto cydoParent = dirName(cydoDir);
	ancestorPaths.require(executableParent, PathAccess.rw, origin);
	ancestorPaths.require(cydoParent, PathAccess.alwaysRw, origin);
	string[string] ancestorEnv = [
		"CYDO_VIBE_BIN": executable,
		"PATH": executableDir,
	];
	agent.configureSandbox(ancestorPaths, ancestorEnv);
	assert(ancestorPaths.exact(executableParent).get.effectiveMode == PathMode.rw);
	assert(ancestorPaths.exact(executableDir).isNull);
	assert(ancestorPaths.exact(cydoParent).get.effectiveMode == PathMode.always_rw);
	assert(ancestorPaths.exact(cydoDir).isNull);
}

unittest
{
	import std.exception : assertThrown;
	import std.file : exists, readText, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto root = buildPath(tempDir(), "cydo-vibe-profile-bootstrap");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto agent = new VibeAgent;

	// Absolute work dir: config.toml suppresses updates and telemetry and pins
	// the resolved active model; trusted_folders.toml trusts the work dir.
	auto profileA = buildPath(root, "profile-a");
	ProcessLaunch launch;
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.vibe, profileA);
	launch.workDir = "/test/workdir";
	SessionConfig config;
	config.model = "medium";
	agent.bootstrapVibeProfile(launch, config);
	auto configToml = readText(buildPath(profileA, "config.toml"));
	assert(configToml.canFind("enable_update_checks = false"));
	assert(configToml.canFind("enable_telemetry = false"));
	assert(configToml.canFind(`active_model = "mistral-medium-3.5"`));
	assert(readText(buildPath(profileA, "trusted_folders.toml"))
		== `trusted = ["/test/workdir"]` ~ "\n");

	// Idempotence: a pre-written config.toml is never clobbered.
	write(buildPath(profileA, "config.toml"), "custom = true\n");
	agent.bootstrapVibeProfile(launch, config);
	assert(readText(buildPath(profileA, "config.toml")) == "custom = true\n");

	// Relative work dir: no trusted_folders.toml is written.
	auto profileB = buildPath(root, "profile-b");
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.vibe, profileB);
	launch.workDir = "relative/dir";
	agent.bootstrapVibeProfile(launch, config);
	assert(exists(buildPath(profileB, "config.toml")));
	assert(!exists(buildPath(profileB, "trusted_folders.toml")));

	// config.workDir is used when launch.workDir is empty.
	auto profileC = buildPath(root, "profile-c");
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.vibe, profileC);
	launch.workDir = null;
	config.workDir = "/test/config-workdir";
	agent.bootstrapVibeProfile(launch, config);
	assert(readText(buildPath(profileC, "trusted_folders.toml"))
		.canFind("/test/config-workdir"));

	// Empty model: no active_model line is written.
	auto profileD = buildPath(root, "profile-d");
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.vibe, profileD);
	launch.workDir = "/test/workdir";
	config.model = null;
	config.workDir = null;
	agent.bootstrapVibeProfile(launch, config);
	assert(!readText(buildPath(profileD, "config.toml")).canFind("active_model"));

	// Empty profile root: a no-op.
	ProcessLaunch emptyLaunch;
	emptyLaunch.workDir = "/test/workdir";
	agent.bootstrapVibeProfile(emptyLaunch, config);

	// Wrong-driver profile is rejected.
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, profileA);
	assertThrown(agent.bootstrapVibeProfile(launch, config));
}

unittest
{
	@JSONPartial static struct NewSessionProbe
	{
		string cwd;
		McpServerStdio[] mcpServers;
	}

	SessionConfig config;
	config.mcpSocketPath = "/test/mcp.sock";
	config.creatableTaskTypes = "types";
	config.switchModes = "modes";
	config.handoffs = "handoffs";
	config.includeTools = ["Task", "Ask"];
	auto params = jsonParse!NewSessionProbe(
		buildNewSessionParams(7, "/test/workdir", config));
	assert(params.cwd == "/test/workdir");
	assert(params.mcpServers.length == 1);
	auto server = params.mcpServers[0];
	assert(server.type == "stdio");
	assert(server.name == "cydo");
	assert(server.command == cydoBinaryPath);
	assert(server.args == ["mcp-server"]);
	assert(server.env.length == 6);
	assert(server.env[0] == EnvVariable("CYDO_TID", "7"));
	assert(server.env[1] == EnvVariable("CYDO_SOCKET", "/test/mcp.sock"));
	assert(server.env[2] == EnvVariable("CYDO_CREATABLE_TYPES", "types"));
	assert(server.env[3] == EnvVariable("CYDO_SWITCHMODES", "modes"));
	assert(server.env[4] == EnvVariable("CYDO_HANDOFFS", "handoffs"));
	assert(server.env[5] == EnvVariable("CYDO_INCLUDE_TOOLS", "Task,Ask"));

	// No MCP socket: no servers are delivered via the handshake.
	config.mcpSocketPath = null;
	assert(jsonParse!NewSessionProbe(
		buildNewSessionParams(7, "/test/workdir", config)).mcpServers.length == 0);
}

unittest
{
	// The initialize handshake gates readiness; session/new adopts the native
	// session ID and publishes it before the synthetic session/init event.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection, true);
	assert(server.state == VibeAcpProcess.State.initializing);
	auto initRequest = connection.takeRequest("initialize");
	auto initParams = jsonParse!VibeInitializeParams(toJson(initRequest.params));
	assert(initParams.protocolVersion == 1);
	assert(initParams.clientCapabilities.fs.readTextFile);
	assert(initParams.clientCapabilities.fs.writeTextFile);
	assert(!initParams.clientCapabilities.terminal);
	assert(initParams.clientInfo.name == "cydo");
	assert(initParams.clientInfo.version_ == "0.1.0");

	string[] nativeIds;
	string[] order;
	auto session = attachSession(server, 1, null, "test-model", "/test/workdir",
		SessionConfig.init);
	session.onNativeSessionStarted = (string sessionId) {
		nativeIds ~= sessionId;
		order ~= "native:" ~ sessionId;
	};
	session.onOutput = (TranslatedEvent event) { order ~= "output"; };

	connection.respond(initRequest,
		acceptedVibeResponse(`{"protocolVersion":1}`));
	drainVibePromiseNextTicks();
	assert(server.state == VibeAcpProcess.State.ready);

	auto newRequest = connection.takeRequest("session/new");
	auto newParams = jsonParse!NewSessionParams(toJson(newRequest.params));
	assert(newParams.cwd == "/test/workdir");
	assert(newParams.mcpServers.length == 0);

	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"native-vibe-1"}`));
	drainVibePromiseNextTicks();
	assert(order == ["native:native-vibe-1", "output"],
		"Vibe must publish its native ID once before synthetic session/init");
	assert(session.sessionId_ == "native-vibe-1" && session.sessionReady_);

	// A late onNativeSessionStarted subscriber is served immediately.
	session.onNativeSessionStarted = (string sessionId) {
		nativeIds ~= sessionId;
	};
	assert(nativeIds == ["native-vibe-1", "native-vibe-1"]);
}

unittest
{
	// The create owner leaves a production sendMessage promise pending until
	// session readiness; the session/prompt response is both the acceptance
	// and the turn boundary, and it releases the gated user echo.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 1, null, "test-model", "/test/workdir",
		SessionConfig.init);
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "pre-ready")],
			"pre-ready-nonce"));
	assertVibePending(submission);
	assert(session.pendingMessages.length == 1);
	assert(connection.sentMessages.length == 1);

	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"native-vibe-1"}`));
	drainVibePromiseNextTicks();
	assertVibePending(submission);
	assert(session.sessionReady_ && session.pendingMessages.length == 0
		&& session.expectedUserMessages.length == 1);
	assert(emitted.length == 1 && emitted[0].canFind(`"type":"session/init"`));
	emitted = null;

	auto promptRequest = connection.takeRequest("session/prompt");
	auto promptParams = jsonParse!PromptParams(toJson(promptRequest.params));
	assert(promptParams.sessionId == "native-vibe-1");
	assert(promptParams.prompt.length == 1);
	assert(promptParams.prompt[0].type == "text");
	assert(promptParams.prompt[0].text == "pre-ready");

	// The native user echo is gated until the session/prompt response accepts
	// the submission, while agent chunks stream immediately.
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"text","text":"pre-"}}`));
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"text","text":"ready"}}`));
	assert(emitted.length == 0, "gated user echo leaked before acceptance");

	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"agent_message_chunk","messageId":"am1","content":{"type":"text","text":"hi there"}}`));
	assert(emitted.length == 2);
	emitted = null;

	connection.respond(promptRequest, acceptedVibeResponse(
		`{"stopReason":"end_turn","usage":{"input_tokens":11,"output_tokens":7}}`));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(submission);
	assert(emitted.length == 4);
	assert(emitted[0].canFind(`"type":"item/completed"`));
	assert(emitted[0].canFind(`"text":"hi there"`));
	assert(emitted[1].canFind(`"type":"turn/stop"`));
	assert(emitted[2].canFind(`"type":"turn/result"`));
	assert(emitted[2].canFind(`"input_tokens":11`));
	assert(emitted[2].canFind(`"output_tokens":7`));
	assert(emitted[2].canFind(`"result":"hi there"`));
	auto echo = jsonParse!ItemStartedEvent(emitted[3]);
	assert(echo.item_type == "user_message");
	assert(echo.correlation_id == "pre-ready-nonce");
	assert(echo.content.length == 1 && echo.content[0].text == "pre-ready");
}

unittest
{
	// A rejected session/prompt restores the idle state, rejects only its own
	// record, and immediately submits the queued successor with a distinct ID.
	auto fixture = makeReadyVibeSession(2);
	auto session = fixture.session;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto rejected = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "reject me")], "reject"));
	auto rejectedRequest = fixture.connection.takeRequest("session/prompt");
	auto successor = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "accept me")], "successor"));
	assertVibePending(rejected);
	assertVibePending(successor);
	assert(session.pendingMessages.length == 1);

	fixture.connection.respond(rejectedRequest,
		rejectedVibeResponse("prompt rejected"));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(rejected, "prompt rejected");
	assertVibePending(successor);
	assert(session.pendingMessages.length == 0
		&& session.expectedUserMessages.length == 1
		&& session.turnInProgress);
	assert(emitted.length == 0,
		"session/prompt rejection fabricated a translated event");

	auto successorRequest = fixture.connection.takeRequest("session/prompt");
	auto successorParams = jsonParse!PromptParams(
		toJson(successorRequest.params));
	assert(successorParams.sessionId == session.sessionId_);
	assert(successorParams.prompt.length == 1);
	assert(successorParams.prompt[0].text == "accept me");
	assert(rejectedRequest.id.toJson() != successorRequest.id.toJson());

	fixture.connection.respond(successorRequest, acceptedVibeResponse(
		`{"stopReason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}`));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(rejected, "prompt rejected");
	assertVibeAcceptedOnce(successor);
	assert(emitted.length == 2,
		"the session/prompt response is the vibe turn boundary");
	assert(emitted[0].canFind(`"type":"turn/stop"`));
	assert(emitted[1].canFind(`"type":"turn/result"`));
}

unittest
{
	void exerciseLifecycleLoss(string label,
		void delegate(VibeSession) loseLifecycle, bool remainsAlive)
	{
		auto fixture = makeReadyVibeSession(3);
		auto session = fixture.session;

		auto inFlight = new TestVibeSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " in flight")],
				label ~ "-flight"));
		auto captured = fixture.connection.takeRequest("session/prompt");
		auto queued = new TestVibeSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " queued")],
				label ~ "-queued"));
		assert(session.expectedUserMessages.length == 1
			&& session.pendingMessages.length == 1);

		loseLifecycle(session);
		loseLifecycle(session);
		drainVibePromiseNextTicks();
		assertVibeRejectedOnce(inFlight);
		assertVibeRejectedOnce(queued);
		assert(session.alive_ == remainsAlive);
		assert(session.expectedUserMessages.length == 0
			&& session.pendingMessages.length == 0);

		fixture.connection.respond(captured,
			acceptedVibeResponse(`{"stopReason":"end_turn"}`));
		drainVibePromiseNextTicks();
		assertVibeRejectedOnce(inFlight);
		assertVibeRejectedOnce(queued);
		assert(session.expectedUserMessages.length == 0
			&& session.pendingMessages.length == 0);
		assert(fixture.connection.sentMessages.length == 0,
			"late response drained or resurrected a submission");
	}

	exerciseLifecycleLoss("invalidation",
		(VibeSession session) {
			session.invalidatePendingSubmittedMessages();
		}, true);
	exerciseLifecycleLoss("exit",
		(VibeSession session) {
			session.handleExit(17);
		}, false);
}

unittest
{
	void exerciseCloseOwner(string label,
		void delegate(VibeSession) closeOwner, int expectedExitStatus)
	{
		auto fixture = makeReadyVibeSession(4, "close-" ~ label);
		auto session = fixture.session;

		int[] exitStatuses;
		session.onExit = (int status) { exitStatuses ~= status; };
		auto inFlight = new TestVibeSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " in flight")],
				label ~ "-flight"));
		auto captured = fixture.connection.takeRequest("session/prompt");
		auto queued = new TestVibeSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " queued")],
				label ~ "-queued"));

		closeOwner(session);
		closeOwner(session);
		auto cancelNotification = fixture.connection
			.takeNotification("session/cancel");
		auto cancelParams = jsonParse!CancelParams(
			toJson(cancelNotification.params));
		assert(cancelParams.sessionId == "close-" ~ label);
		assert(fixture.connection.sentMessages.length == 0);
		drainVibePromiseNextTicks();
		assertVibeRejectedOnce(inFlight);
		assertVibeRejectedOnce(queued);
		assert(exitStatuses == [expectedExitStatus]);
		assert(fixture.server.dead && !session.alive);

		fixture.connection.respond(captured,
			acceptedVibeResponse(`{"stopReason":"end_turn"}`));
		drainVibePromiseNextTicks();
		assertVibeRejectedOnce(inFlight);
		assertVibeRejectedOnce(queued);
		assert(fixture.connection.sentMessages.length == 0);
	}

	exerciseCloseOwner("stdin",
		(VibeSession session) { session.closeStdin(); }, 0);
	exerciseCloseOwner("stop",
		(VibeSession session) { session.stop(); }, 1);
}

unittest
{
	// Initialize rejection exercises failStartup and the pending session
	// callback, including a message queued before vibe readiness.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection, true);
	auto initRequest = connection.takeRequest("initialize");
	auto session = attachSession(server, 5, null, "test-model", "/test/workdir",
		SessionConfig.init);
	auto queued = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "wait for initialize")],
			"init-queued"));
	assertVibePending(queued);

	connection.respond(initRequest, rejectedVibeResponse("initialize rejected"));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(queued, "initialize rejected");
	assert(server.state == VibeAcpProcess.State.failed && server.dead);
	assert(!session.alive_);

	session.handleStartupFailure(
		new Exception("duplicate initialize failure"));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(queued, "initialize rejected");
}

unittest
{
	void exerciseSessionSetupFailure(string resumeSessionId,
		string expectedMethod)
	{
		auto connection = new TestVibeConnection;
		auto server = makeTestVibeAcpProcess(connection);
		auto sessionId = resumeSessionId.length > 0
			? resumeSessionId : "setup-failure";
		auto session = attachSession(server, 6, resumeSessionId, "test-model",
			"/test/workdir", SessionConfig.init);
		auto setupRequest = connection.takeRequest(expectedMethod);
		if (resumeSessionId.length > 0)
		{
			auto params = jsonParse!LoadSessionParams(
				toJson(setupRequest.params));
			assert(params.sessionId == sessionId
				&& params.cwd == "/test/workdir");
			assert(session.replayMode);
		}
		else
		{
			auto params = jsonParse!NewSessionParams(
				toJson(setupRequest.params));
			assert(params.cwd == "/test/workdir");
		}

		string[] emitted;
		session.onOutput = (TranslatedEvent event) {
			emitted ~= event.translated;
		};
		auto queued = new TestVibeSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "queued setup")],
				"setup-queued"));
		assertVibePending(queued);
		assert(connection.sentMessages.length == 0);

		connection.respond(setupRequest, rejectedVibeResponse("setup rejected"));
		drainVibePromiseNextTicks();
		auto expectedError = expectedMethod ~ " error: setup rejected";
		assertVibeRejectedOnce(queued, expectedError);
		assert(!session.alive_ && !session.sessionReady_);
		assert(session.pendingMessages.length == 0
			&& session.expectedUserMessages.length == 0);
		assert(connection.sentMessages.length == 0);
		if (resumeSessionId.length > 0)
		{
			assert(!session.replayMode);
			assert(emitted.length == 1 && emitted[0].canFind(expectedError));
		}
		else
			assert(emitted.length == 0);

		session.handleStartupFailure(new Exception("duplicate setup failure"));
		drainVibePromiseNextTicks();
		assertVibeRejectedOnce(queued, expectedError);
	}

	exerciseSessionSetupFailure(null, "session/new");
	exerciseSessionSetupFailure("resume-failure", "session/load");
}

unittest
{
	// session/load replay: updates arriving before the response are replayed
	// (is_replay, no correlation); resume markers are consumed; the response
	// ends replay mode and emits the synthetic session/init.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 8, "native-vibe-8", "test-model",
		"/test/workdir", SessionConfig.init);
	auto loadRequest = connection.takeRequest("session/load");
	auto loadParams = jsonParse!LoadSessionParams(toJson(loadRequest.params));
	assert(loadParams.sessionId == "native-vibe-8");
	assert(loadParams.cwd == "/test/workdir");
	assert(session.replayMode);

	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"user_message_chunk","messageId":"replay-m1","content":{"type":"text","text":"earlier question"}}`));
	assert(emitted.length == 1);
	auto replayItem = jsonParse!ItemStartedEvent(emitted[0]);
	assert(replayItem.item_type == "user_message");
	assert(replayItem.is_replay);
	assert(replayItem.correlation_id is null);
	assert(replayItem.content.length == 1
		&& replayItem.content[0].text == "earlier question");
	emitted = null;

	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"tool_call","toolCallId":"checkpoint:resume:0","_meta":{"tool_name":"think"}}`));
	assert(emitted.length == 0);

	connection.respond(loadRequest, acceptedVibeResponse());
	drainVibePromiseNextTicks();
	assert(!session.replayMode && session.sessionReady_);
	assert(emitted.length == 1 && emitted[0].canFind(`"type":"session/init"`));
}

unittest
{
	// Item identity: lazy items are keyed by the vibe messageId within a
	// per-turn namespace; a type or key switch finalizes the previous item.
	auto fixture = makeReadyVibeSession(9);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "hello")], "chunk-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Hel"}}`));
	assert(emitted.length == 2);
	auto m1Start = jsonParse!ItemStartedEvent(emitted[0]);
	assert(m1Start.item_id == "vb-text-1-0" && m1Start.item_type == "text");
	auto m1Delta = jsonParse!ItemDeltaEvent(emitted[1]);
	assert(m1Delta.item_id == "vb-text-1-0"
		&& m1Delta.delta_type == "text_delta" && m1Delta.content == "Hel");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"lo"}}`));
	assert(emitted.length == 3);

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"agent_thought_chunk","messageId":"m2","content":{"type":"text","text":"hmm"}}`));
	assert(emitted.length == 6);
	auto m1Done = jsonParse!ItemCompletedEvent(emitted[3]);
	assert(m1Done.item_id == "vb-text-1-0" && m1Done.text == "Hello");
	auto m2Start = jsonParse!ItemStartedEvent(emitted[4]);
	assert(m2Start.item_id == "vb-think-1-1"
		&& m2Start.item_type == "thinking");
	auto m2Delta = jsonParse!ItemDeltaEvent(emitted[5]);
	assert(m2Delta.item_id == "vb-think-1-1"
		&& m2Delta.delta_type == "thinking_delta" && m2Delta.content == "hmm");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"agent_message_chunk","messageId":"m3","content":{"type":"text","text":"!"}}`));
	assert(emitted.length == 9);
	auto m2Done = jsonParse!ItemCompletedEvent(emitted[6]);
	assert(m2Done.item_id == "vb-think-1-1");
	auto m3Start = jsonParse!ItemStartedEvent(emitted[7]);
	assert(m3Start.item_id == "vb-text-1-2" && m3Start.item_type == "text");
	auto m3Delta = jsonParse!ItemDeltaEvent(emitted[8]);
	assert(m3Delta.item_id == "vb-text-1-2" && m3Delta.content == "!");
}

unittest
{
	// Tool lifecycle: tool_call emits item/started plus the full input as a
	// single input_json_delta; completion emits item/completed and item/result
	// with plain text extracted from the content array, rawOutput fallbacks,
	// and the failure flag.
	auto fixture = makeReadyVibeSession(10);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "run tool")], "tool-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t1","rawInput":{"command":"ls"},"_meta":{"tool_name":"bash"}}`));
	assert(emitted.length == 2);
	auto started = jsonParse!ItemStartedEvent(emitted[0]);
	assert(started.item_type == "tool_use" && started.name == "bash");
	assert(started.item_id == "vb-tool-t1");
	assert(started.input.json == `{"command":"ls"}`);
	auto inputDelta = jsonParse!ItemDeltaEvent(emitted[1]);
	assert(inputDelta.item_id == "vb-tool-t1");
	assert(inputDelta.delta_type == "input_json_delta");
	assert(inputDelta.content == `{"command":"ls"}`);

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"done output"}}]}`));
	assert(emitted.length == 4);
	assert(emitted[2].canFind(`"type":"item/completed"`));
	auto result = jsonParse!ItemResultEvent(emitted[3]);
	assert(result.item_id == "vb-tool-t1");
	assert(jsonParse!string(result.content.json) == "done output");
	assert(!result.is_error);

	// rawOutput fallback: a plain string becomes the item/result content.
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t1b","rawInput":{},"_meta":{"tool_name":"bash"}}`));
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t1b","status":"completed","rawOutput":"plain output"}`));
	// rawInput {} is the empty-input sentinel: no input_json_delta is emitted.
	assert(emitted.length == 7);
	auto plainResult = jsonParse!ItemResultEvent(emitted[6]);
	assert(jsonParse!string(plainResult.content.json) == "plain output");

	// A failed tool call flags item/result with is_error.
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t1c","rawInput":{"cmd":true},"_meta":{"tool_name":"bash"}}`));
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t1c","status":"failed","rawOutput":"boom"}`));
	assert(emitted.length == 11);
	auto failedResult = jsonParse!ItemResultEvent(emitted[10]);
	assert(failedResult.item_id == "vb-tool-t1c");
	assert(failedResult.is_error);
}

unittest
{
	// A tool_call without rawInput emits item/started only; the first update
	// carrying the input emits it late. The tool is force-completed at the
	// turn boundary.
	auto fixture = makeReadyVibeSession(11);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "late input")],
			"late-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t2","_meta":{"tool_name":"bash"}}`));
	assert(emitted.length == 1);
	auto started = jsonParse!ItemStartedEvent(emitted[0]);
	assert(started.item_id == "vb-tool-t2" && started.name == "bash");
	assert(started.input.json == `{}`);

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t2","rawInput":{"command":"pwd"}}`));
	assert(emitted.length == 2);
	auto lateInput = jsonParse!ItemDeltaEvent(emitted[1]);
	assert(lateInput.item_id == "vb-tool-t2");
	assert(lateInput.delta_type == "input_json_delta");
	assert(lateInput.content == `{"command":"pwd"}`);

	fixture.connection.respond(promptRequest,
		acceptedVibeResponse(`{"stopReason":"end_turn"}`));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(submission);
	assert(emitted.length == 6);
	assert(emitted[2].canFind(`"type":"item/completed"`));
	assert(emitted[2].canFind(`"input":{"command":"pwd"}`));
	assert(emitted[3].canFind(`"type":"item/result"`));
	assert(emitted[4].canFind(`"type":"turn/stop"`));
	assert(emitted[5].canFind(`"type":"turn/result"`));
}

unittest
{
	// cydo_-prefixed MCP tool names are decomposed: the canonical name loses
	// the prefix and the item records the cydo MCP server as its source.
	auto fixture = makeReadyVibeSession(12);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "delegate")], "task-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t3","rawInput":{"mode":"plan"},"_meta":{"tool_name":"cydo_Task"}}`));
	assert(emitted.length == 2);
	auto started = jsonParse!ItemStartedEvent(emitted[0]);
	assert(started.item_type == "tool_use");
	assert(started.name == "Task");
	assert(started.tool_server == "cydo");
	assert(started.tool_source == "mcp");
	assert(started.input.json == `{"mode":"plan"}`);
}

unittest
{
	// Compaction surfaces as a checkpoint tool_call pair — both halves are
	// consumed and one session/compacted is emitted at completion; a
	// checkpoint:resume marker is consumed silently.
	auto fixture = makeReadyVibeSession(13);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "compact")], "compact-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"c1","_meta":{"checkpoint_kind":"compaction","tool_name":"think"}}`));
	assert(emitted.length == 0);

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","_meta":{"checkpoint_kind":"compaction"}}`));
	assert(emitted.length == 1);
	assert(emitted[0].canFind(`"type":"session/compacted"`));

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"checkpoint:resume:5","_meta":{"tool_name":"think"}}`));
	assert(emitted.length == 1);

	fixture.connection.respond(promptRequest,
		acceptedVibeResponse(`{"stopReason":"end_turn"}`));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(submission);
	assert(emitted.length == 3);
	assert(emitted[1].canFind(`"type":"turn/stop"`));
	assert(emitted[2].canFind(`"type":"turn/result"`));
}

unittest
{
	// Diff blocks in a completed tool call are preserved verbatim in
	// item/result content.
	auto fixture = makeReadyVibeSession(14);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "edit")], "diff-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t4","rawInput":{"path":"a.txt"},"_meta":{"tool_name":"edit"}}`));
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t4","status":"completed","content":[{"type":"diff","path":"a.txt","old_string":"x","new_string":"y"}]}`));
	assert(emitted.length == 4);
	auto result = jsonParse!ItemResultEvent(emitted[3]);
	assert(result.item_id == "vb-tool-t4");
	assert(result.content.json.canFind(`"type":"diff"`));
	assert(result.content.json.canFind(`"old_string":"x"`));
	assert(result.content.json.canFind(`"new_string":"y"`));
	assert(!result.is_error);
}

unittest
{
	// Ignored update kinds produce no events; unknown updates and updates
	// that fail to deserialize become agent/unrecognized events.
	auto fixture = makeReadyVibeSession(15);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "noise")], "noise-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");

	foreach (ignoredUpdate; [
		`{"sessionUpdate":"usage_update","usage":{}}`,
		`{"sessionUpdate":"plan","plan":{}}`,
		`{"sessionUpdate":"available_commands_update","commands":[]}`,
		`{"sessionUpdate":"current_mode_update","mode":"default"}`,
		`{"sessionUpdate":"config_option_update","option":{}}`,
		`{"sessionUpdate":"session_info_update","info":{}}`,
	])
		fixture.connection.receive(vibeUpdate(sid, ignoredUpdate));
	assert(emitted.length == 0);

	fixture.connection.receive(vibeUpdate(sid, `{"sessionUpdate":"notice"}`));
	assert(emitted.length == 1);
	assert(emitted[0].canFind(`"type":"agent/unrecognized"`));
	assert(emitted[0].canFind("unknown vibe update: notice"));

	fixture.connection.receive(vibeUpdate(sid, `{"sessionUpdate":true}`));
	assert(emitted.length == 2);
	assert(emitted[1].canFind(`"type":"agent/unrecognized"`));
	assert(emitted[1].canFind("malformed vibe session update"));
}

unittest
{
	// Permission requests are auto-approved with allow_once for a registered
	// session and answered with a cancelled outcome for unknown sessions;
	// updates for unknown sessions are dropped silently.
	auto fixture = makeReadyVibeSession(16);
	auto session = fixture.session;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	fixture.connection.receive(`{"jsonrpc":"2.0","id":101,"method":"session/request_permission","params":{"sessionId":"`
		~ session.sessionId_ ~ `","toolCall":{"toolCallId":"t9"}}}`);
	drainVibePromiseNextTicks();
	assert(fixture.connection.sentMessages.length == 1);
	assert(fixture.connection.sentMessages[0].canFind(`"outcome":"selected"`));
	assert(fixture.connection.sentMessages[0].canFind(`"optionId":"allow_once"`));

	fixture.connection.receive(`{"jsonrpc":"2.0","id":102,"method":"session/request_permission","params":{"sessionId":"no-such-session","toolCall":{"toolCallId":"t9"}}}`);
	drainVibePromiseNextTicks();
	assert(fixture.connection.sentMessages.length == 2);
	assert(fixture.connection.sentMessages[1].canFind(`"outcome":"cancelled"`));
	assert(!fixture.connection.sentMessages[1].canFind(`"optionId"`));

	fixture.connection.receive(vibeUpdate("no-such-session",
		`{"sessionUpdate":"agent_message_chunk","messageId":"x","content":{"type":"text","text":"orphan"}}`));
	drainVibePromiseNextTicks();
	assert(emitted.length == 0);
	assert(fixture.connection.sentMessages.length == 2);
}
