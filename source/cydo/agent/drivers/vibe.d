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
import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode, JsonRpcRequest,
	JsonRpcResponse;
import ae.utils.promise : Promise, resolve;
import ae.utils.serialization.store : SerializedObject;

version (unittest) import ae.net.asockets : ConnectionState, DisconnectType;
version (unittest) import ae.sys.data : Data;

import cydo.agent.contract : Agent, DiscoveredSession, InterruptedToolCallRepair,
	OneShotHandle, PersistedHistoryBoundary, PersistedHistoryBoundaryKind,
	RewindResult, SessionConfig, SessionMeta;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt;
import cydo.protocol : ContentBlock, extractContentText, ItemCompletedEvent,
	ItemDeltaEvent, ItemResultEvent, ItemStartedEvent, makeUnrecognizedEvent,
	ProcessExitEvent, ProcessStderrEvent, SessionCompactedEvent, SessionInitEvent,
	TranslatedEvent, TurnResultEvent, TurnStopEvent, UsageInfo;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox : cleanup, cydoBinaryDir, cydoBinaryPath,
	effectiveEnvValue, executableMountPaths, resolveExecutablePath,
	withProcessLaunchEnv;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;

private alias SO = SerializedObject!(immutable char);

// ---------------------------------------------------------------------------
// ACP wire structs — protocol v1, verified against vibe-acp 2.25.4–2.26.1
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
	@JSONOptional string text;
	// image blocks: base64 data + MIME (ACP ContentBlock image shape).
	@JSONOptional string data;
	@JSONOptional string mimeType;
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

// session/set_config_option (stable, ACP v1): the select-option variant
// (mode, model, thinking) carries the value as a plain JSON string —
// verified against vibe-acp 2.25.8–2.26.1, which reject a {value: "<id>"}
// object with -32602 "Input should be a valid string".
private struct SetConfigOptionParams
{
	string sessionId;
	string configId;
	string value;
}

// session/set_mode (stable, ACP v1): {sessionId, modeId}.
private struct SetModeParams
{
	string sessionId;
	string modeId;
}

// Persisted LLM-message format (S5): one message per line in
// messages.jsonl, `{"role": "user"|"assistant"|"tool", ...}`. Assistant
// lines carry `content`, `reasoning_content` and `tool_calls` when present;
// tool lines carry `content`, `name` and `tool_call_id`.
@JSONPartial
private struct VibeHistoryToolCallFunction
{
	string name;
	@JSONOptional string arguments;
}

@JSONPartial
private struct VibeHistoryToolCall
{
	string id;
	@JSONName("function") VibeHistoryToolCallFunction function_;
}

@JSONPartial
private struct VibeMetaFile
{
	string session_id;
	@JSONOptional string origin_directory;
	@JSONOptional string title;
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

// Vibe's SDK validates RequestPermissionResponse.outcome as a nested object
// ({outcome: {outcome: "selected", optionId}}, 2.25.4–2.25.8 pydantic contract), not
// a flat string.
private struct PermissionOutcome
{
	PermissionOption outcome;

	static PermissionOutcome allowOnce()
	{
		PermissionOutcome result;
		result.outcome = PermissionOption("selected", "allow_once");
		return result;
	}

	static PermissionOutcome cancelled()
	{
		PermissionOutcome result;
		result.outcome = PermissionOption("cancelled", null);
		return result;
	}
}

private struct PermissionOption
{
	string outcome;
	@JSONOptional string optionId;

	this(string outcome_, string optionId_)
	{
		outcome = outcome_;
		optionId = optionId_;
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

	// A fault contained by AgentProcess while running a stdout/stderr
	// line handler (mirrors the Claude driver's reportLineHandlerError).
	void handleLineHandlerError(string source, Exception e);
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

		// A fault escaping a stdout/stderr line handler is contained by
		// AgentProcess; surface it as a task diagnostic on the sessions
		// this process serves instead of unwinding the event loop (one
		// process serves one task's session, so the routing is exact).
		process.onLineHandlerError = (string source, Exception e) {
			if (pendingSession !is null)
				pendingSession.handleLineHandlerError(source, e);
			foreach (session; sessions)
				session.handleLineHandlerError(source, e);
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
		// A failed handshake must not short-circuit: State.failed leaves
		// the child running with stdin open, and startup failures route
		// through VibeSession.handleStartupFailure, which relies on
		// shutdown to terminate the process. Only an already-dead process
		// (or a completed shutdown) is a no-op.
		if (state_ == State.dead || process.dead)
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
		// Advertise only what IVibeAcpServer actually serves: the client fs
		// capabilities are not implemented, and an agent that trusted a
		// true advertisement would get method-not-found for every
		// fs/read_text_file / fs/write_text_file request.
		params.clientCapabilities.fs.readTextFile = false;
		params.clientCapabilities.fs.writeTextFile = false;
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
	int shutdownCount;

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
		shutdownCount++;
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

version (unittest) private TestVibeAcpProcess makeTestVibeAcpProcess(
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

		// vibe 3.x generates a background session title per ACP session
		// (one extra model call CyDo does not need — CyDo titles tasks
		// itself). Suppress it for CyDo-spawned sessions only; the env
		// override is per child process, so the user's own vibe sessions
		// keep their titles (verified against vibe-acp 3.0.1).
		env["VIBE_SESSION_LOGGING__GENERATE_TITLES"] = "false";
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

		// S2-verified: vibe-acp is stdio-only; no launch flags. vibe 3.x
		// removed --legacy-harness along with the legacy runtime: sessions
		// always use the Unified Harness, which stores transcripts in the
		// chunked logs/session/unified/<uuid>/ store. This driver's history
		// subsystem (live watch, fork, undo) reads and writes the legacy
		// logs/session/session_<ts>_<id8>/messages.jsonl layout, so the
		// driver keeps its own transcript per session (see VibeSession's
		// transcript writer) instead of relying on vibe's store.
		//
		// On resume, vibe would restore from its own unified store, which
		// predates any CyDo-side transcript edits (mode-switch reframe,
		// undo). Discard it so session/load imports the driver's transcript
		// and the resumed context matches what the UI shows.
		if (resumeSessionId.length > 0)
			discardUnifiedStoreForResume(resumeSessionId,
				launch.nativeHistoryProfile);
		auto vibeBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		string[] vibeArgs = [vibeBin];
		string[] args = launch.cmdPrefix !is null
			? launch.cmdPrefix ~ vibeArgs : vibeArgs;

		auto server = new VibeAcpProcess(args, null, null, "vibe");
		return attachSession(server, tid, resumeSessionId, model, workDir, config,
			launch.nativeHistoryProfile);
	}

	/// Write the profile bootstrap files when a native-history profile root
	/// is present: config.toml (only when absent, so an existing user
	/// profile is never clobbered) suppressing update checks and telemetry,
	/// and trusted_folders.toml (only when absent and the task work dir is
	/// absolute) so sessions start trusted.
	///
	/// NOTE: the profile root is shared (typically the user's real
	/// ~/.vibe), not per-task — the first CyDo task bootstraps these files
	/// for every later vibe use, CyDo or not. The per-task model is not
	/// pinned here: it is applied per session via the `model` config
	/// option (see applySessionOptions).
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
			string contents = "# managed by CyDo — shared Vibe profile bootstrap\n"
				~ "enable_update_checks = false\n"
				~ "enable_telemetry = false\n";
			write(configPath, contents);
		}

		auto trustedPath = buildPath(root, "trusted_folders.toml");
		if (!exists(trustedPath))
		{
			auto workDir = launch.workDir.length > 0
				? launch.workDir : config.workDir;
			if (workDir.isAbsolute)
				write(trustedPath, "trusted = [\"" ~ tomlEscapeBasicString(workDir)
					~ "\"]\n");
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
			// vibe 3.x's model catalog exposes a tiered lineup; the aliases
			// below are the catalog IDs that resolve on the Mistral hosted
			// backend. vibe-acp rejects an unknown alias in
			// session/set_config_option ("Unsupported config option
			// model=..."), which fails session startup, and the one-shot CLI
			// silently falls back to the default. Users wanting a different
			// model configure `model_aliases` (or a custom [[models]] entry).
			case "small":  return "mistral-small-2603";
			case "medium": return "mistral-medium-3.5";
			case "large":  return "mistral-large-4";
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

	// Vibe persists one LLM message per line under
	// $VIBE_HOME/logs/session/session_<ts>_<id8>/messages.jsonl (S5-verified).
	// The directory name embeds the first 8 hex chars of the session UUID;
	// the timestamp prefix forces a scan rather than a direct join.
	string historyPath(string sessionId, const ref NativeHistoryProfile profile)
	{
		import std.file : dirEntries, exists, SpanMode;
		import std.path : baseName;
		import std.algorithm : sort;
		import std.array : split;

		if (sessionId.length < 8 || profile.root.length == 0)
			return null;
		auto sessionsDir = buildPath(profile.root, "logs", "session");
		if (!sessionsDir.exists)
			return null;
		auto prefix = sessionId[0 .. 8];
		string[string] byPath;
		try
			foreach (entry; dirEntries(sessionsDir, "session_*", SpanMode.shallow))
			{
				auto name = baseName(entry.name);
				auto parts = name.split("_");
				if (parts.length < 4 || parts[3].length < 8)
					continue;
				if (parts[3][0 .. 8] != prefix)
					continue;
				auto candidate = buildPath(entry.name, "messages.jsonl");
				if (candidate.exists)
					byPath[entry.name] = candidate;
			}
		catch (Exception)
			return null;
		if (byPath.length == 0)
			return null;
		// Multiple dirs (fork/compaction chains) — the newest wins.
		auto names = byPath.keys.sort.release;
		return byPath[names[$ - 1]];
	}

	/// Discard vibe 3.x's chunked unified store for a session about to be
	/// resumed via session/load. vibe restores from
	/// $VIBE_HOME/logs/session/unified/<sessionId>/ when present, ignoring
	/// the driver-written legacy transcript that CyDo may have edited since
	/// (keep_context mode-switch reframe, undo truncation, fork). Deleting
	/// the store makes session/load import the legacy transcript instead, so
	/// the resumed LLM context matches the transcript. No-op when the
	/// session has no driver-written transcript — vibe's store is then the
	/// only copy and must be kept.
	void discardUnifiedStoreForResume(string sessionId,
		const ref NativeHistoryProfile profile)
	{
		import std.file : exists, rmdirRecurse;
		import std.logger : tracef;

		if (sessionId.length == 0 || profile.root.length == 0)
			return;
		if (historyPath(sessionId, profile).length == 0)
			return;
		auto storeDir = buildPath(profile.root, "logs", "session", "unified",
			sessionId);
		try
		{
			if (storeDir.exists)
			{
				rmdirRecurse(storeDir);
				tracef("discardUnifiedStoreForResume: removed %s", storeDir);
			}
		}
		catch (Exception e)
			tracef("discardUnifiedStoreForResume: failed to remove %s: %s",
				storeDir, e.msg);
	}

	void registerHistoryPath(string sessionId, string path,
		const ref NativeHistoryProfile profile)
	{
		// Session dirs are named session_<ts>_<id8> — the timestamp prefix
		// makes the full path non-derivable from the session ID alone, so a
		// learned locator cannot be validated against a derivation. The live
		// watch rescans by id8 prefix on demand instead.
	}

	string createHistoryForkDestination(string sessionId, string sourceHistoryPath,
		const ref NativeHistoryProfile profile)
	{
		import std.datetime : Clock;
		import std.file : exists, mkdirRecurse, readText, write;
		import std.format : format;
		import std.path : dirName;
		import std.string : lineSplitter;

		enforce(profile.driver == driver,
			"Vibe history fork requires the Mistral Vibe history profile");
		enforce(sessionId.length >= 8,
			"Vibe history fork requires an 8+ char session ID");

		// A resumable fork needs its own session dir whose meta.json carries
		// the forked session_id — messages.jsonl alone is not loadable.
		// Dir name mirrors vibe's own layout: session_<ts>_<first 8 of id>.
		auto sessionsDir = buildPath(profile.root, "logs", "session");
		auto sourceDir = dirName(sourceHistoryPath);
		auto sourceMetaPath = buildPath(sourceDir, "meta.json");
		auto sourceMeta = readVibeMetaFile(sourceMetaPath);

		auto now = Clock.currTime;
		auto id8 = sessionId[0 .. 8];
		auto newDir = buildPath(sessionsDir,
			format!"session_%04d%02d%02d_%02d%02d%02d_%s"(now.year,
				cast(int) now.month, now.day, now.hour, now.minute, now.second,
				id8));
		mkdirRecurse(newDir);

		// vibe's SessionMetadata (pydantic) requires session_id, start_time,
		// end_time, git_commit, git_branch, environment, username; the loader
		// additionally keys total_messages. Verified against 2.26.1: a
		// synthesized dir with this shape resumes via session/load, and a
		// wrong total_messages is tolerated (metadata only, not validated
		// against the transcript).
		string username = "cydo";
		long totalMessages = 0;
		if (exists(sourceMetaPath))
		{
			import std.json : JSONType, parseJSON;
			try
			{
				auto source = parseJSON(readText(sourceMetaPath));
				if (source.type == JSONType.object
					&& "username" in source.object
					&& source.object["username"].type == JSONType.string)
					username = source.object["username"].str;
			}
			catch (Exception) {}
		}
		if (exists(sourceHistoryPath))
			foreach (line; readText(sourceHistoryPath).lineSplitter)
				if (line.length > 0)
					totalMessages++;

		auto originDirectory = sourceMeta.originDirectory.length > 0
			? sourceMeta.originDirectory : sourceDir;
		auto timestamp = format!"%04d-%02d-%02dT%02d:%02d:%02d.000000+00:00"(
			now.year, cast(int) now.month, now.day, now.hour, now.minute,
			now.second);
		auto meta = "{\n"
			~ "  \"session_id\": " ~ toJson(sessionId) ~ ",\n"
			~ "  \"parent_session_id\": null,\n"
			~ "  \"start_time\": " ~ toJson(timestamp) ~ ",\n"
			~ "  \"end_time\": " ~ toJson(timestamp) ~ ",\n"
			~ "  \"git_commit\": null,\n"
			~ "  \"git_branch\": null,\n"
			~ "  \"environment\": {\"working_directory\": "
				~ toJson(originDirectory) ~ "},\n"
			~ "  \"origin_directory\": " ~ toJson(originDirectory) ~ ",\n"
			~ "  \"username\": " ~ toJson(username) ~ ",\n"
			~ "  \"child_sessions\": [],\n"
			~ "  \"loops\": [],\n"
			~ "  \"title\": null,\n"
			~ "  \"title_source\": \"auto\",\n"
			~ "  \"total_messages\": " ~ to!string(totalMessages) ~ "\n"
			~ "}";
		write(buildPath(newDir, "meta.json"), meta);
		return buildPath(newDir, "messages.jsonl");
	}

	void resetHistoryReplay()
	{
	}

	/// Read a persisted user-line image attachment as base64. The backend
	/// is unsandboxed while the profile dir is writable inside the agent
	/// sandbox, so a crafted history line must not be able to make the
	/// backend read an arbitrary host file (or block on a FIFO, or eat
	/// memory on /dev/zero): only a regular file that resolves, after
	/// realpath, inside the session dir holding the history file is
	/// inlined, with a size cap. Returns null otherwise.
	private static string readHistoryImageAttachment(string imagePath,
		string historyPath)
	{
		import std.base64 : Base64;
		import std.file : getSize, isFile, read;
		import std.path : dirName;
		import ae.sys.file : realPath;

		enum maxImageBytes = 32 * 1024 * 1024;
		if (imagePath.length == 0 || historyPath.length == 0)
			return null;
		try
		{
			auto sessionDir = realPath(dirName(historyPath));
			auto resolved = realPath(imagePath); // throws when the path is missing
			if (!resolved.isFile || !resolved.startsWith(sessionDir ~ "/"))
				return null;
			if (getSize(resolved) > maxImageBytes)
				return null;
			auto bytes = read(resolved);
			return cast(string) Base64.encode(cast(ubyte[]) bytes);
		}
		catch (Exception)
			return null;
	}

	// One persisted LLM message per line (S5); vibe-internal records carry
	// injected=true and are not part of the transcript. Translation mirrors
	// the live VibeSession shapes so history reload and live rendering agree:
	// the vb-tool-<id> item ids pair tool results with their tool_use items,
	// and a plain-content assistant message closes the turn because
	// messages.jsonl has no explicit turn marker.
	// historyPath gates image inlining: persisted image paths must resolve
	// inside the session dir that holds the history file (see
	// readHistoryImageAttachment).
	TranslatedEvent[] translateHistoryLine(string line, int lineNum,
		string historyPath = null)
	{
		import std.format : format;

		@JSONPartial static struct RoleProbe
		{
			string role;
			@JSONOptional string message_id;
			@JSONOptional bool injected;
		}
		RoleProbe probe;
		try probe = jsonParse!RoleProbe(line);
		catch (Exception)
			return [];
		if (probe.injected)
			return [];
		// Lines without a message_id fall back to a line-number anchor,
		// like Claude's history translation.
		auto anchor = probe.message_id.length > 0 ? probe.message_id
			: format!"line:%d"(lineNum);

		TranslatedEvent[] events;
		switch (probe.role)
		{
			case "user":
			{
				@JSONPartial static struct PersistedImageSource
				{
					@JSONOptional string kind;
					@JSONOptional string path;
				}
				@JSONPartial static struct PersistedImage
				{
					@JSONOptional PersistedImageSource source;
					@JSONOptional string mime_type;
				}
				@JSONPartial static struct UserProbe
				{
					string content;
					@JSONOptional PersistedImage[] images;
				}
				UserProbe ev;
				try ev = jsonParse!UserProbe(line);
				catch (Exception)
					return [];
				if (ev.content.length == 0)
					return [];
				ContentBlock cb;
				cb.type = "text";
				cb.text = ev.content;
				ContentBlock[] content = [cb];
				// Persisted images are session-dir attachment files; inline
				// them back as base64 blocks so the reloaded transcript shows
				// what the model saw. A path outside the session dir, a
				// non-regular file or an oversized one is skipped silently —
				// the message degrades to text-only.
				foreach (ref image; ev.images)
				{
					if (image.source.path.length == 0)
						continue;
					auto encoded = readHistoryImageAttachment(
						image.source.path, historyPath);
					if (encoded.length == 0)
						continue;
					ContentBlock imageBlock;
					imageBlock.type = "image";
					imageBlock.data = encoded;
					imageBlock.media_type = image.mime_type.length > 0
						? image.mime_type : "image/png";
					content ~= imageBlock;
				}
				ItemStartedEvent startEv;
				startEv.item_id = "vb-hist-user-" ~ anchor;
				startEv.item_type = "user_message";
				startEv.content = content;
				startEv.uuid = probe.message_id;
				events ~= TranslatedEvent(toJson(startEv), line);
				break;
			}
			case "assistant":
			{
				@JSONPartial static struct AssistantProbe
				{
					@JSONOptional string content;
					@JSONOptional string reasoning_content;
					@JSONOptional JSONFragment tool_calls;
				}
				AssistantProbe ev;
				try ev = jsonParse!AssistantProbe(line);
				catch (Exception)
					return [];

				// Thinking precedes text, mirroring the live chunk order.
				if (ev.reasoning_content.length > 0)
				{
					auto id = "vb-hist-think-" ~ anchor;
					ItemStartedEvent thinkStartEv;
					thinkStartEv.item_id = id;
					thinkStartEv.item_type = "thinking";
					ItemCompletedEvent thinkCompEv;
					thinkCompEv.item_id = id;
					thinkCompEv.text = ev.reasoning_content;
					events ~= TranslatedEvent(toJson(thinkStartEv), line);
					events ~= TranslatedEvent(toJson(thinkCompEv), line);
				}
				if (ev.content.length > 0)
				{
					auto id = "vb-hist-text-" ~ anchor;
					ItemStartedEvent textStartEv;
					textStartEv.item_id = id;
					textStartEv.item_type = "text";
					ItemCompletedEvent textCompEv;
					textCompEv.item_id = id;
					textCompEv.text = ev.content;
					events ~= TranslatedEvent(toJson(textStartEv), line);
					events ~= TranslatedEvent(toJson(textCompEv), line);
				}
				if (ev.tool_calls.json.length > 0 && ev.tool_calls.json != "null")
				{
					VibeHistoryToolCall[] calls;
					try calls = jsonParse!(VibeHistoryToolCall[])(ev.tool_calls.json);
					catch (Exception) {}
					foreach (call; calls)
					{
						// Same naming contract as the live translation:
						// cydo_<tool> MCP names decompose into the canonical
						// name plus the cydo server (the transcript writer
						// normalizes vibe 3.x's mcp_cydo.<tool> to cydo_<tool>).
						auto name = call.function_.name.length > 0
							? call.function_.name : "unknown";
						ItemStartedEvent toolStartEv;
						toolStartEv.item_id = "vb-tool-" ~ call.id;
						toolStartEv.item_type = "tool_use";
						auto parts = decomposeVibeToolName(name);
						toolStartEv.name = parts.displayName;
						if (parts.toolServer.length > 0)
						{
							toolStartEv.tool_server = parts.toolServer;
							toolStartEv.tool_source = parts.toolSource;
						}
						toolStartEv.input = JSONFragment(
							call.function_.arguments.length > 0
								? call.function_.arguments : `{}`);
						events ~= TranslatedEvent(toJson(toolStartEv), line);
					}
					// A tool_calls segment ends the streaming message
					// whether or not text preceded it in the same line
					// (like claude's per-message-stop shape), so the
					// frontend ends the message here and the following
					// plain-text line opens its own message (and
					// raw-source span) instead of merging with the tool
					// segment. The turn itself is still mid-flight: the
					// tool results and the turn's real end follow.
					TurnStopEvent toolStopEv;
					events ~= TranslatedEvent(toJson(toolStopEv), line);
				}
				// A plain-content assistant line with no tool calls
				// terminates the turn: synthesize the live protocol's
				// turn/stop + turn/result pair. Text plus tool_calls in one
				// line is mid-turn, so no turn/result is synthesized here.
				if (ev.content.length > 0
					&& !(ev.tool_calls.json.length > 0 && ev.tool_calls.json != "null"))
				{
					TurnStopEvent stopEv;
					events ~= TranslatedEvent(toJson(stopEv), line);
					TurnResultEvent resultEv;
					resultEv.subtype = "success";
					resultEv.is_error = false;
					resultEv.num_turns = 1;
					resultEv.duration_ms = 0;
					resultEv.total_cost_usd = 0.0;
					resultEv.result = ev.content;
					resultEv.usage = UsageInfo(0, 0);
					events ~= TranslatedEvent(toJson(resultEv), line);
				}
				break;
			}
			case "tool":
			{
				@JSONPartial static struct ToolProbe
				{
					@JSONOptional string content;
					@JSONOptional string tool_call_id;
					@JSONOptional JSONFragment tool_result;
				}
				ToolProbe ev;
				try ev = jsonParse!ToolProbe(line);
				catch (Exception)
					return [];
				if (ev.tool_call_id.length == 0)
					return [];
				auto id = "vb-tool-" ~ ev.tool_call_id;
				ItemCompletedEvent compEv;
				compEv.item_id = id;
				events ~= TranslatedEvent(toJson(compEv), line);
				ItemResultEvent resEv;
				resEv.item_id = id;
				resEv.content = JSONFragment(toJson(ev.content));
				// Keep the structured CyDo payload on the reloaded item like
				// the live translation does (finalizeTool).
				auto structuredJson = vibeStructuredPayload(ev.tool_result);
				if (structuredJson.length > 0)
					resEv.tool_result = JSONFragment(structuredJson);
				events ~= TranslatedEvent(toJson(resEv), line);
				break;
			}
			default:
				return [];
		}
		return events;
	}

	@property string lastMcpConfigPath() { return null; }

	string rewriteSessionId(string line, string oldId, string newId)
	{
		// messages.jsonl carries per-message ids only; the session id lives
		// in the sibling meta.json, which this line-level hook cannot rewrite.
		return line;
	}

	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content,
		int lineOffset = 0)
	{
		import std.format : format;
		import std.string : lineSplitter;

		PersistedHistoryBoundary[] ids;
		int lineNum = lineOffset;
		foreach (line; content.lineSplitter)
		{
			lineNum++;
			if (line.length == 0)
				continue;
			try
			{
				@JSONPartial static struct BoundaryProbe
				{
					string role;
					@JSONOptional string message_id;
					@JSONOptional bool injected;
				}
				auto probe = jsonParse!BoundaryProbe(line);
				if (probe.injected)
					continue;
				if (probe.role != "user" && probe.role != "assistant")
					continue;
				auto anchor = probe.message_id.length > 0 ? probe.message_id
					: format!"line:%d"(lineNum);
				ids ~= PersistedHistoryBoundary(anchor,
					probe.role == "user" ? PersistedHistoryBoundaryKind.user
						: PersistedHistoryBoundaryKind.agent_turn,
					null, lineNum);
			}
			catch (Exception) {}
		}
		return ids;
	}

	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText)
	{
		// CyDo interrupts the session right after a successful
		// continuation MCP call so the agent yields; vibe persists the
		// interrupted call as an assistant tool_calls line plus a
		// role:"tool" record whose content carries the
		// `<user_cancellation>` marker (verified against vibe-acp
		// 2.26.1). Rewrite that record to the intended result so the
		// resumed context reports the successful switch instead of a
		// user cancellation — mirroring the claude driver's rejection
		// repair. Returns null when the expected shape is not present
		// (e.g. the result was already recorded before the interrupt),
		// leaving the file untouched.
		import std.algorithm : canFind, startsWith;
		import std.json : JSONType, JSONValue, parseJSON;

		// The caller passes the claude-style full MCP name
		// (mcp__cydo__SwitchMode); vibe persists the vibe-side
		// `cydo_SwitchMode` tool name.
		string canonical = toolName;
		if (canonical.startsWith("mcp__cydo__"))
			canonical = canonical["mcp__cydo__".length .. $];
		string vibeToolName = "cydo_" ~ canonical;

		string toolCallId;
		foreach (line; lines)
		{
			JSONValue record;
			try
				record = parseJSON(line);
			catch (Exception)
				continue;
			if (record.type != JSONType.object)
				continue;
			auto role = "role" in record.object
				&& record.object["role"].type == JSONType.string
				? record.object["role"].str : null;
			auto toolCalls = "tool_calls" in record.object
				&& record.object["tool_calls"].type == JSONType.array
				? record.object["tool_calls"].array : null;
			if (role != "assistant" || toolCalls is null)
				continue;
			foreach (ref call; toolCalls)
			{
				if (call.type != JSONType.object || !("function" in call.object))
					continue;
				auto function_ = call.object["function"];
				if (function_.type != JSONType.object
					|| !("name" in function_.object)
					|| function_.object["name"].type != JSONType.string)
					continue;
				if (function_.object["name"].str == vibeToolName
					&& "id" in call.object
					&& call.object["id"].type == JSONType.string)
					toolCallId = call.object["id"].str;
			}
		}
		if (toolCallId.length == 0)
			return null;

		string[] rewritten;
		bool repaired = false;
		foreach (line; lines)
		{
			JSONValue record;
			try
				record = parseJSON(line);
			catch (Exception)
			{
				rewritten ~= line;
				continue;
			}
			if (!repaired && record.type == JSONType.object
				&& "role" in record.object
				&& record.object["role"].type == JSONType.string
				&& record.object["role"].str == "tool"
				&& "tool_call_id" in record.object
				&& record.object["tool_call_id"].type == JSONType.string
				&& record.object["tool_call_id"].str == toolCallId
				&& "content" in record.object
				&& record.object["content"].type == JSONType.string
				&& record.object["content"].str.canFind("<user_cancellation>"))
			{
				record.object["content"] = JSONValue(resultText);
				rewritten ~= record.toString();
				repaired = true;
			}
			else
				rewritten ~= line;
		}
		if (!repaired)
			return null;
		return new InterruptedToolCallRepair(rewritten);
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		if (forkId.startsWith("line:"))
		{
			import std.conv : to;
			try
				return lineNum == forkId["line:".length .. $].to!int;
			catch (Exception)
				return false;
		}
		@JSONPartial static struct IdProbe { @JSONOptional string message_id; }
		try
			return jsonParse!IdProbe(line).message_id == forkId;
		catch (Exception)
			return false;
	}

	bool isForkableLine(string line)
	{
		@JSONPartial static struct RoleProbe { string role; }
		try
		{
			auto role = jsonParse!RoleProbe(line).role;
			return role == "user" || role == "assistant";
		}
		catch (Exception)
			return false;
	}

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
		@JSONPartial static struct RoleProbe
		{
			string role;
			@JSONOptional bool injected;
		}
		try
		{
			auto probe = jsonParse!RoleProbe(rawLine);
			return probe.role == "user" && !probe.injected;
		}
		catch (Exception)
			return false;
	}

	bool isAssistantMessageLine(string rawLine)
	{
		@JSONPartial static struct RoleProbe
		{
			string role;
			@JSONOptional bool injected;
		}
		try
		{
			auto probe = jsonParse!RoleProbe(rawLine);
			return probe.role == "assistant" && !probe.injected;
		}
		catch (Exception)
			return false;
	}

	@property bool needsBash() { return true; }

	@property bool supportsFileRevert() { return false; }

	@property bool supportsDeveloperPrompt() { return false; }

	RewindResult rewindFiles(string sessionId, string afterUuid, ProcessLaunch launch)
	{
		return RewindResult(false, "File revert is not supported for Vibe sessions");
	}

	// Vibe stores one session dir under
	// $VIBE_HOME/logs/session/session_<ts>_<id8>/ with meta.json + messages.jsonl
	// (S5). The dir name carries only the first 8 chars of the session UUID, so
	// enumeration reads meta.json for the full resumable ID — one small JSON
	// read per candidate dir.
	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		import std.file : DirEntry, dirEntries, exists, isDir, SpanMode,
			timeLastModified;

		enforce(profile.driver == driver,
			"Vibe history profile driver does not match Mistral Vibe");
		auto sessionsDir = buildPath(profile.root, "logs", "session");
		if (!exists(sessionsDir) || !isDir(sessionsDir))
			return [];

		DiscoveredSession[] result;
		try
		{
			foreach (DirEntry dirEntry;
				dirEntries(sessionsDir, "session_*", SpanMode.shallow))
			{
				if (!dirEntry.isDir)
					continue;
				auto messagesPath = buildPath(dirEntry.name, "messages.jsonl");
				if (!exists(messagesPath))
					continue;
				auto meta = readVibeMetaFile(
					buildPath(dirEntry.name, "meta.json"));
				// Without the full session ID the session cannot be resumed —
				// a missing or unreadable meta.json disqualifies the dir.
				if (meta.sessionId.length == 0)
					continue;
				DiscoveredSession ds;
				ds.sessionId = meta.sessionId;
				ds.mtime = timeLastModified(messagesPath).stdTime;
				ds.projectPath = meta.originDirectory;
				ds.exactHistoryPath = messagesPath;
				result ~= ds;
			}
		}
		catch (Exception e)
		{
			import std.logger : tracef;
			tracef("enumerateAllSessions(vibe): error scanning %s: %s",
				sessionsDir, e.msg);
		}
		return result;
	}

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		import std.path : dirName;
		import cydo.foundation.text.title : truncateTitle;

		if (session.exactHistoryPath.length == 0)
			return SessionMeta.init;

		SessionMeta meta;
		auto fileMeta = readVibeMetaFile(
			buildPath(dirName(session.exactHistoryPath), "meta.json"));
		meta.title = fileMeta.title;
		meta.projectPath = fileMeta.originDirectory;

		// meta.json's title is nullable and defaults to "auto"; fall back to
		// the first real user message, and count messages the same way.
		import std.stdio : File;
		try
		{
			int lineCount = 0;
			auto f = File(session.exactHistoryPath, "r");
			foreach (line; f.byLine)
			{
				if (lineCount++ > 50)
					break;
				string lineStr = cast(string) line.idup;
				try
				{
					@JSONPartial static struct FirstUserProbe
					{
						string role;
						@JSONOptional string content;
						@JSONOptional bool injected;
					}
					auto probe = jsonParse!FirstUserProbe(lineStr);
					if (probe.role != "user" || probe.injected)
						continue;
					meta.hasMessages = true;
					if (meta.title.length == 0)
						meta.title = truncateTitle(probe.content, 80);
				}
				catch (Exception) {}
				if (meta.hasMessages && meta.title.length > 0)
					break;
			}
		}
		catch (Exception e)
		{
			import std.logger : tracef;
			tracef("readSessionMeta(vibe, %s): error: %s",
				session.sessionId, e.msg);
		}
		return meta;
	}

	string matchProject(const ref DiscoveredSession session,
		const string[] knownProjectPaths)
	{
		// projectPath comes from meta.json's origin_directory at enumeration;
		// this fallback only re-checks it against the known list.
		if (session.projectPath.length == 0)
			return "";
		foreach (known; knownProjectPaths)
			if (known == session.projectPath)
				return known;
		return "";
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		auto promise = new Promise!string;
		auto spec = resolveModelSpec(modelClass);

		// One-shots run through vibe-acp itself (see VibeOneShotAcp): vibe
		// 3.x removed the legacy runtime, and the one-shot `vibe` CLI's
		// app-server spawn path shells out to `uv`, which is absent in the
		// sandbox. The session's executablePath (vibe-acp) is the binary.
		//
		// The no-tools guard rides two layers (see VibeOneShotAcp): the
		// session is switched to "ask" mode with every permission request
		// denied, and the mutating built-in tools are denied outright via a
		// per-child VIBE_TOOLS override (vibe 3.x has no config-level way to
		// disable the built-in harness tools, and a tool configured
		// `permission = "always"` would otherwise bypass the ask-mode gate).
		// The override is per child process, so the main session's tool
		// permissions are untouched.
		ProcessLaunch oneShotLaunch;
		bool hasOneShotLaunch;
		string[string] procEnv;
		try
		{
			if (launch.cmdPrefix !is null)
			{
				oneShotLaunch = withProcessLaunchEnv(launch, "VIBE_TOOLS",
					vibeOneShotNoToolsJson);
				hasOneShotLaunch = true;
			}
			else
			{
				procEnv = buildVibeOneShotEnv();
				procEnv["VIBE_TOOLS"] = vibeOneShotNoToolsJson;
			}
		}
		catch (Exception e)
		{
			promise.reject(new Exception(
				"failed to prepare vibe one-shot launch: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		auto effectiveLaunch = hasOneShotLaunch ? oneShotLaunch : launch;
		auto acpBin = effectiveLaunch.executablePath.length > 0
			? effectiveLaunch.executablePath
			: executableName(effectiveLaunch.sandbox.env);
		auto args = buildVibeOneShotArgs(acpBin, effectiveLaunch);

		auto workDir = effectiveLaunch.workDir.length > 0
			? effectiveLaunch.workDir : null;

		VibeOneShotAcp oneShot;
		try
			oneShot = new VibeOneShotAcp(args, procEnv, workDir, spec.model,
				prompt, promise);
		catch (Exception e)
		{
			if (hasOneShotLaunch)
				cleanup(oneShotLaunch.sandbox);
			promise.reject(new Exception("failed to spawn vibe-acp: " ~ e.msg));
			return OneShotHandle(promise, null);
		}
		if (hasOneShotLaunch)
			oneShot.onSettled = { cleanup(oneShotLaunch.sandbox); };

		void cancel() { oneShot.cancel(); }

		return OneShotHandle(promise, &cancel);
	}
}

/// Per-child `VIBE_TOOLS` override for one-shots: deny the mutating
/// built-in tools outright (`permission = "never"`). vibe 3.x's Unified
/// Harness has no config-level way to disable its built-in tools, and a
/// tool the user configured `permission = "always"` would otherwise bypass
/// the one-shot's ask-mode gate (verified against vibe-acp 3.0.1: the
/// override denies the call with "Tool execution denied by approval
/// policy" and the turn completes). The env layer deep-merges this over
/// the profile's `[tools.*]` tables for the one-shot child only.
private static immutable string vibeOneShotNoToolsJson =
	`{"bash":{"permission":"never"},` ~
	`"read_file":{"permission":"never"},` ~
	`"write_file":{"permission":"never"},` ~
	`"edit":{"permission":"never"},` ~
	`"skill":{"permission":"never"}}`;

/// Spawn arguments for the one-shot vibe-acp child: the binary, behind the
/// sandbox prefix when one is configured.
private static string[] buildVibeOneShotArgs(string acpBin, ProcessLaunch launch)
{
	string[] args = [acpBin];
	if (launch.cmdPrefix !is null)
		args = launch.cmdPrefix ~ args;
	return args;
}

/// Minimal environment for the unsandboxed one-shot child. PATH and HOME
/// always ride along; vibe's provider reachability keys (API key, profile
/// root, proxies) pass through when set so users who configure the
/// interactive path via env instead of ~/.vibe/.env keep working one-shot
/// completions — the same passthrough list as configureSandbox. The
/// sandboxed child inherits the parent environment wholesale via the
/// sandbox prefix, so it needs no override here.
private static string[string] buildVibeOneShotEnv()
{
	import std.process : environment;

	string[string] env = [
		"PATH": environment.get("PATH", ""),
		"HOME": environment.get("HOME", ""),
	];
	foreach (key; ["MISTRAL_API_KEY", "VIBE_HOME", "HTTPS_PROXY", "NO_PROXY"])
	{
		auto value = environment.get(key, "");
		if (value.length > 0)
			env[key] = value;
	}
	// Suppress vibe's background session-title generation for one-shots
	// (see configureSandbox).
	env["VIBE_SESSION_LOGGING__GENERATE_TITLES"] = "false";
	return env;
}

// ---------------------------------------------------------------------------
// VibeOneShotAcp — a minimal ACP client for one-shot completions (titles,
// suggestions). vibe 3.x removed the legacy runtime, and the one-shot
// `vibe` CLI's app-server spawn path shells out to `uv` (absent in the
// sandbox), so one-shots run through vibe-acp itself: a throwaway session
// with no MCP servers, switched to "ask" mode with every permission
// request denied — the ACP-level equivalent of the 2.x
// `--enabled-tools __cydo_no_tools__` guard, so no tool can execute on
// untrusted prompt content (titles and suggestions are generated from
// conversation history, which may include untrusted file or web text).
// ---------------------------------------------------------------------------

private class VibeOneShotAcp
{
	private AgentProcess process;
	private JsonRpcCodec codec;
	private Promise!string promise;
	private string workDir;
	private string responseText;
	private string stderrText;
	private bool settled;

	/// Called once when the one-shot settles (success, failure, or exit),
	/// so the caller can release launch-clone resources.
	void delegate() onSettled;

	this(string[] args, string[string] env, string workDir, string model,
		string prompt, Promise!string promise)
	{
		this.promise = promise;
		this.workDir = workDir;
		process = new AgentProcess(args, env, workDir, false,
			FramingMode.ndjson, "vibe-oneshot");
		codec = new JsonRpcCodec(process.connection);
		codec.handleRequest = &handleAgentRequest;

		process.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};
		process.onExit = (int status) { handleExit(status); };

		sendInitialize(model, prompt);
	}

	version (unittest) private this(IConnection connection, string model,
		string prompt, Promise!string promise)
	{
		this.promise = promise;
		codec = new JsonRpcCodec(connection);
		codec.handleRequest = &handleAgentRequest;
		sendInitialize(model, prompt);
	}

	void cancel()
	{
		// No-op once the one-shot has settled.
		if (settled || process is null)
			return;
		process.killAfterTimeout(0.seconds);
	}

	private Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = jsonParse!SO(params);
		return codec.sendRequest(req);
	}

	private void sendNotification(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = jsonParse!SO(params);
		codec.sendNotification(req);
	}

	/// Agent → client messages: accumulate assistant text chunks; deny
	/// every permission request (the no-tools guard — see the class
	/// comment). Any other request (e.g. an elicitation for a user
	/// question) gets a method-not-found error, which fails that tool
	/// call without hanging the turn.
	private Promise!JsonRpcResponse handleAgentRequest(JsonRpcRequest request)
	{
		if (request.method == "session/update")
		{
			try
			{
				auto params = request.params.deserializeTo!SessionUpdateParams();
				auto update = params.update.deserializeTo!VibeSessionUpdate();
				if (update.sessionUpdate == "agent_message_chunk")
					responseText ~= chunkText(update.content);
			}
			catch (Exception) {}
			return resolve(JsonRpcResponse.init);
		}
		if (request.method == "session/request_permission")
		{
			JsonRpcResponse resp;
			resp.id = request.id;
			resp.result = jsonParse!SO(toJson(PermissionOutcome.cancelled()));
			return resolve(resp);
		}
		if (request.isNotification)
			return resolve(JsonRpcResponse.init);
		JsonRpcResponse resp;
		resp.id = request.id;
		resp.error = JsonRpcError.fromCode(JsonRpcErrorCode.methodNotFound,
			"unsupported one-shot request: " ~ request.method);
		return resolve(resp);
	}

	private void fail(Exception e)
	{
		if (settled)
			return;
		settled = true;
		shutdown();
		if (onSettled !is null)
			onSettled();
		promise.reject(e);
	}

	private void succeed()
	{
		if (settled)
			return;
		settled = true;
		shutdown();
		if (onSettled !is null)
			onSettled();
		import std.string : strip;
		promise.fulfill(responseText.strip());
	}

	private void handleExit(int status)
	{
		if (settled)
			return;
		auto msg = "vibe-acp exited with status " ~ status.to!string;
		import std.string : strip;
		auto details = stderrText.strip();
		if (details.length > 0)
			msg ~= ": " ~ details;
		fail(new Exception(msg));
	}

	private void shutdown()
	{
		if (process is null || process.dead)
			return;
		process.closeStdin();
		process.terminate();
		process.killAfterTimeout(3.seconds);
	}

	private void sendInitialize(string model, string prompt)
	{
		VibeInitializeParams params;
		params.protocolVersion = 1;
		params.clientCapabilities.fs.readTextFile = false;
		params.clientCapabilities.fs.writeTextFile = false;
		params.clientCapabilities.terminal = false;
		VibeClientInfo clientInfo;
		clientInfo.name = "cydo";
		clientInfo.version_ = "0.1.0";
		params.clientInfo = clientInfo;
		sendRequest("initialize", toJson(params))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					fail(new Exception("initialize error: "
						~ resp.error.get.message));
					return;
				}
				sendNewSession(model, prompt);
			}, (Exception e) { fail(e); });
	}

	private void sendNewSession(string model, string prompt)
	{
		NewSessionParams params;
		// The one-shot prompt needs no workspace; vibe requires a cwd, so
		// use the launch work dir (the child process's own cwd).
		params.cwd = workDir.length > 0 ? workDir : ".";
		params.mcpServers = null;
		sendRequest("session/new", toJson(params))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					fail(new Exception("session/new error: "
						~ resp.error.get.message));
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
					fail(new Exception("session/new response has no session ID"));
					return;
				}
				applyAskMode(sessionId, model, prompt);
			}, (Exception e) { fail(e); });
	}

	/// Switch the throwaway session to "ask" mode so every tool execution
	/// requires approval — which this client then denies (the no-tools
	/// guard). Applied before the model is pinned and the prompt sent.
	private void applyAskMode(string sessionId, string model, string prompt)
	{
		SetModeParams params;
		params.sessionId = sessionId;
		params.modeId = "ask";
		sendRequest("session/set_mode", toJson(params))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					fail(new Exception("session/set_mode error: "
						~ resp.error.get.message));
					return;
				}
				applyModel(sessionId, model, prompt);
			}, (Exception e) { fail(e); });
	}

	private void applyModel(string sessionId, string model, string prompt)
	{
		if (model.length == 0)
		{
			sendPrompt(sessionId, prompt);
			return;
		}
		SetConfigOptionParams params;
		params.sessionId = sessionId;
		params.configId = "model";
		params.value = model;
		sendRequest("session/set_config_option", toJson(params))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					fail(new Exception("session/set_config_option error: "
						~ resp.error.get.message));
					return;
				}
				sendPrompt(sessionId, prompt);
			}, (Exception e) { fail(e); });
	}

	private void sendPrompt(string sessionId, string prompt)
	{
		PromptParams params;
		params.sessionId = sessionId;
		VibePromptBlock block;
		block.text = prompt;
		params.prompt = [block];
		sendRequest("session/prompt", toJson(params))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					fail(new Exception("session/prompt error: "
						~ resp.error.get.message));
					return;
				}
				succeed();
			}, (Exception e) { fail(e); });
	}
}

/// Escape a value for a TOML basic ("…") string: backslash and double
/// quote are escaped so paths spliced into trusted_folders.toml cannot
/// break out of the string or corrupt the file.
private static string tomlEscapeBasicString(string value)
{
	import std.array : replace;

	return value
		.replace("\\", "\\\\")
		.replace("\"", "\\\"");
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

	// Vibe's SDK validates every env entry as a strict {name, value} string
	// pair; a JSON null value fails the handshake (2.25.4–2.25.8 pydantic contract),
	// so optional values are omitted rather than emitted as null.
	EnvVariable[] env;
	env ~= EnvVariable("CYDO_TID", to!string(tid));
	env ~= EnvVariable("CYDO_SOCKET", config.mcpSocketPath);
	if (config.creatableTaskTypes !is null)
		env ~= EnvVariable("CYDO_CREATABLE_TYPES", config.creatableTaskTypes);
	if (config.switchModes !is null)
		env ~= EnvVariable("CYDO_SWITCHMODES", config.switchModes);
	if (config.handoffs !is null)
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

/// Apply CyDo's per-session model and effort once the session exists, then
/// hand control to the ready path. The model rides the `model` config
/// option (S8: a select option on session/new, verified accepted by
/// session/set_config_option against vibe-acp 2.26.1) so each task's
/// resolved model class is honoured per session instead of depending on
/// the profile's global `active_model`. The launch `effort` parameter maps
/// to vibe's `thinking` option (off/low/medium/high/max per S8). Empty
/// values leave vibe's configured default untouched. A rejected option
/// fails the startup — mirroring how an invalid model or effort value
/// fails the claude CLI at spawn (handleStartupFailure then terminates
/// the leaked process).
private void applySessionOptions(VibeAcpProcess server, string sessionId,
	string model, SessionConfig config, void delegate() onReady,
	void delegate(Exception) onFail)
{
	void sendOption(string configId, string value, void delegate() next)
	{
		SetConfigOptionParams params;
		params.sessionId = sessionId;
		params.configId = configId;
		params.value = value;
		server.sendRequest("session/set_config_option", toJson(params))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					onFail(new Exception(
						"session/set_config_option error: " ~ resp.error.get.message));
					return;
				}
				next();
			}, (Exception e) { onFail(e); });
	}

	void applyEffort()
	{
		if (config.effort.length == 0)
		{
			onReady();
			return;
		}
		sendOption("thinking", config.effort, onReady);
	}

	if (model.length == 0)
	{
		applyEffort();
		return;
	}
	sendOption("model", model, &applyEffort);
}

/// Read a session dir's meta.json (session_id, origin_directory, title).
/// A missing or malformed file yields the default (empty sessionId), which
/// callers treat as "not resumable".
private struct VibeSessionMeta
{
	string sessionId;
	string originDirectory;
	string title;
}

private VibeSessionMeta readVibeMetaFile(string path)
{
	import std.file : exists, readText;

	VibeSessionMeta result;
	if (!exists(path))
		return result;
	try
	{
		auto meta = jsonParse!VibeMetaFile(readText(path));
		result.sessionId = meta.session_id;
		result.originDirectory = meta.origin_directory;
		result.title = meta.title;
	}
	catch (Exception) {}
	return result;
}

// ---------------------------------------------------------------------------
// attachSession — spawn-side wiring, mirrors copilot.d's attachSession.
// ---------------------------------------------------------------------------

private VibeSession attachSession(VibeAcpProcess server, int tid,
	string resumeSessionId, string model, string workDir, SessionConfig config,
	NativeHistoryProfile transcriptProfile = NativeHistoryProfile.init)
{
	auto session = new VibeSession(server, tid, model, workDir, config.agentName,
		transcriptProfile);

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
					applySessionOptions(server, resumeSessionId, model, config, {
						session.onSessionStarted();
					}, (Exception e) {
						session.stopReplay();
						server.unregisterSession(resumeSessionId);
						server.forgetSession(session);
						session.handleStartupFailure(e);
					});
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
					applySessionOptions(server, sessionId, model, config, {
						session.onSessionStarted();
					}, (Exception e) {
						server.unregisterSession(sessionId);
						server.forgetSession(session);
						session.handleStartupFailure(e);
					});
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
	private bool replayMode; // true during session/load replay; replayed content is consumed (persisted history is the transcript source)
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
		string vibeName;    // vibe-side tool name (e.g. "cydo_SwitchMode")
		string toolCallId;  // vibe toolCallId
	}
	private ToolItem[string] activeTools; // keyed by toolCallId

	private string lastResultText; // last completed text content, for turn/result

	// Transcript writer. vibe 3.x removed the legacy runtime, so sessions
	// are stored in the chunked logs/session/unified/<uuid>/ store and no
	// messages.jsonl is written. The driver keeps its own legacy-shaped
	// messages.jsonl per session (written from the live ACP stream) so the
	// history pipeline — live watch, fork, undo, export — works unchanged.
	private NativeHistoryProfile transcriptProfile_;
	private string transcriptPath_; // .../session_<ts>_<id8>/messages.jsonl
	private string transcriptDir_;

	// Accumulator for the assistant LLM message currently streaming:
	// thinking + text + tool_calls group into one legacy assistant line
	// (the persisted translator synthesizes turn/result only for a
	// plain-content line, so the grouping must match the live turn shape).
	private struct AssistantAccum
	{
		string baseUuid;    // shared uuid of the reasoning-/assistant- chunks
		string messageId;   // assistant-<uuid> preferred, else reasoning-...
		string thinking;
		string text;
		string[] toolCalls; // serialized tool-call JSON objects
	}
	private AssistantAccum assistantAccum_;
	private bool assistantAccumActive_;

	// Raw/timestamp plumbing for the update currently being translated.
	private string currentRawJson_;

	private bool sessionReady_; // true after session/new|load response

	// Bumped whenever in-flight submissions are voided (exit, invalidate,
	// failed startup) so their late session/prompt responses are dropped
	// instead of finalizing turns for a dead lifecycle.
	private ulong submissionEpoch_;

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
		ulong epoch; // submissionEpoch_ at submit time; a bump voids it
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
		string agentName = null,
		NativeHistoryProfile transcriptProfile = NativeHistoryProfile.init)
	{
		this.server = server;
		this.tid = tid;
		this.model = model;
		this.workDir = workDir;
		this.agentName_ = agentName;
		this.transcriptProfile_ = transcriptProfile;
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

	// ----- Transcript writer (vibe 3.x unified store has no messages.jsonl) -----

	/// Locate or create this session's legacy-shaped transcript dir and
	/// return its messages.jsonl path. Reuses an existing legacy dir for
	/// the session (driver-written during a previous live run, a 2.26.x
	/// vibe dir, or a CyDo-synthesized fork) so appends continue it;
	/// otherwise creates a new session_<ts>_<id8>/ dir with meta.json.
	private string ensureTranscriptPath()
	{
		if (transcriptPath_.length > 0)
			return transcriptPath_;
		if (transcriptProfile_.root.length == 0 || sessionId_.length < 8)
			return null;
		import std.file : exists, mkdirRecurse, write;
		import std.path : buildPath, dirName;

		auto sessionsDir = buildPath(transcriptProfile_.root, "logs", "session");
		// Reuse an existing legacy dir for this session id.
		try
		{
			import std.file : dirEntries, SpanMode;
			import std.path : baseName;
			import std.array : split;
			auto prefix = sessionId_[0 .. 8];
			foreach (entry; dirEntries(sessionsDir, "session_*", SpanMode.shallow))
			{
				auto name = baseName(entry.name);
				auto parts = name.split("_");
				if (parts.length < 4 || parts[3].length < 8)
					continue;
				if (parts[3][0 .. 8] != prefix)
					continue;
				auto candidate = buildPath(entry.name, "messages.jsonl");
				if (candidate.exists)
				{
					transcriptPath_ = candidate;
					transcriptDir_ = dirName(candidate);
					return transcriptPath_;
				}
			}
		}
		catch (Exception) {}

		// Create a new legacy-layout dir, mirroring createHistoryForkDestination.
		import std.datetime : Clock;
		import std.format : format;
		auto now = Clock.currTime;
		auto id8 = sessionId_[0 .. 8];
		auto newDir = buildPath(sessionsDir,
			format!"session_%04d%02d%02d_%02d%02d%02d_%s"(now.year,
				cast(int) now.month, now.day, now.hour, now.minute, now.second,
				id8));
		try
		{
			mkdirRecurse(newDir);
			auto timestamp = format!"%04d-%02d-%02dT%02d:%02d:%02d.000000+00:00"(
				now.year, cast(int) now.month, now.day, now.hour, now.minute,
				now.second);
			auto originDirectory = workDir.length > 0 ? workDir : ".";
			auto meta = "{\n"
				~ "  \"session_id\": " ~ toJson(sessionId_) ~ ",\n"
				~ "  \"parent_session_id\": null,\n"
				~ "  \"start_time\": " ~ toJson(timestamp) ~ ",\n"
				~ "  \"end_time\": " ~ toJson(timestamp) ~ ",\n"
				~ "  \"git_commit\": null,\n"
				~ "  \"git_branch\": null,\n"
				~ "  \"environment\": {\"working_directory\": "
					~ toJson(originDirectory) ~ "},\n"
				~ "  \"origin_directory\": " ~ toJson(originDirectory) ~ ",\n"
				~ "  \"username\": \"cydo\",\n"
				~ "  \"child_sessions\": [],\n"
				~ "  \"loops\": [],\n"
				~ "  \"title\": null,\n"
				~ "  \"title_source\": \"auto\",\n"
				~ "  \"total_messages\": 0\n"
				~ "}";
			write(buildPath(newDir, "meta.json"), meta);
			write(buildPath(newDir, "messages.jsonl"), "");
			transcriptPath_ = buildPath(newDir, "messages.jsonl");
			transcriptDir_ = newDir;
		}
		catch (Exception) {}
		return transcriptPath_;
	}

	private void appendTranscriptLine(string line)
	{
		if (transcriptPath_.length == 0)
			return;
		try
		{
			import std.file : append;
			append(transcriptPath_, line ~ "\n");
		}
		catch (Exception) {}
	}

	/// The shared uuid of one assistant LLM message: text chunks carry
	/// `assistant-<uuid>` and thinking chunks `reasoning-<uuid>-<n>`.
	private static string assistantBaseUuid(string messageId)
	{
		import std.string : startsWith, lastIndexOf;
		if (messageId.startsWith("assistant-"))
			return messageId["assistant-".length .. $];
		if (messageId.startsWith("reasoning-"))
		{
			auto rest = messageId["reasoning-".length .. $];
			auto dash = rest.lastIndexOf('-');
			if (dash > 0)
				return rest[0 .. dash];
			return rest;
		}
		return messageId;
	}

	/// Write the user line for a completed echo. Images are persisted as
	/// session-dir attachment files and referenced by path, matching the
	/// shape the persisted translator inlines (readHistoryImageAttachment).
	private void writeUserTranscriptLine(PendingMessage submission, string text,
		string messageId)
	{
		if (ensureTranscriptPath().length == 0)
			return;
		import std.base64 : Base64;
		import std.file : mkdirRecurse, write;
		import std.path : buildPath;
		import std.format : format;

		string imagesJson;
		int imageIndex;
		foreach (ref block; submission.content)
		{
			if (block.type != "image" || block.data.length == 0)
				continue;
			auto ext = block.media_type == "image/jpeg" ? "jpg"
				: block.media_type == "image/gif" ? "gif"
				: block.media_type == "image/webp" ? "webp" : "png";
			auto fileName = format!"%s-%d.%s"(messageId, imageIndex++, ext);
			auto relPath = buildPath("images", fileName);
			auto absPath = buildPath(transcriptDir_, relPath);
			try
			{
				mkdirRecurse(buildPath(transcriptDir_, "images"));
				write(absPath, cast(ubyte[]) Base64.decode(block.data));
			}
			catch (Exception)
				continue;
			imagesJson ~= (imagesJson.length > 0 ? "," : "")
				~ `{"source": {"kind": "file", "path": ` ~ toJson(absPath)
				~ `}, "mime_type": ` ~ toJson(
					block.media_type.length > 0 ? block.media_type : "image/png")
				~ `}`;
		}
		auto line = `{"role": "user", "content": ` ~ toJson(text)
			~ `, "injected": false, "message_id": ` ~ toJson(messageId);
		if (imagesJson.length > 0)
			line ~= `, "images": [` ~ imagesJson ~ `]`;
		line ~= `}`;
		appendTranscriptLine(line);
	}

	/// Write the accumulated assistant line (thinking + text + tool_calls)
	/// and reset the accumulator. No-op when nothing accumulated.
	private void flushAssistantLine()
	{
		if (!assistantAccumActive_)
			return;
		assistantAccumActive_ = false;
		if (ensureTranscriptPath().length == 0)
			return;
		auto accum = assistantAccum_;
		assistantAccum_ = AssistantAccum.init;
		if (accum.text.length == 0 && accum.thinking.length == 0
			&& accum.toolCalls.length == 0)
			return;
		auto messageId = accum.messageId.length > 0
			? accum.messageId : accum.baseUuid;
		auto line = `{"role": "assistant"`;
		if (accum.thinking.length > 0)
			line ~= `, "reasoning_content": ` ~ toJson(accum.thinking);
		if (accum.text.length > 0)
			line ~= `, "content": ` ~ toJson(accum.text);
		line ~= `, "injected": false, "message_id": ` ~ toJson(messageId);
		if (accum.toolCalls.length > 0)
		{
			import std.array : join;
			line ~= `, "tool_calls": [` ~ accum.toolCalls.join(",") ~ `]`;
		}
		line ~= `}`;
		appendTranscriptLine(line);
	}

	/// Write the tool-result line for a completed tool call.
	private void writeToolTranscriptLine(ToolItem tool, VibeSessionUpdate update)
	{
		if (ensureTranscriptPath().length == 0)
			return;
		auto resultText = extractToolResultText(update.content, update.rawOutput);
		auto line = `{"role": "tool", "content": ` ~ toJson(resultText)
			~ `, "injected": false, "name": ` ~ toJson(tool.vibeName)
			~ `, "tool_call_id": ` ~ toJson(tool.toolCallId);
		auto structuredJson = vibeStructuredPayload(update.rawOutput);
		if (structuredJson.length > 0)
			line ~= `, "tool_result": ` ~ structuredJson;
		line ~= `}`;
		appendTranscriptLine(line);
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
		// Soft removal: with acceptance at submit time, the user echo may
		// have already completed (and consumed) the expected entry.
		foreach (i, expected; expectedUserMessages)
			if (expected.submission is submission)
			{
				expectedUserMessages = expectedUserMessages[0 .. i]
					~ expectedUserMessages[i + 1 .. $];
				return;
			}
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
		// Void every in-flight submission: their late session/prompt
		// responses must be dropped, not finalized.
		submissionEpoch_++;
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
		assistantAccum_ = AssistantAccum.init;
		assistantAccumActive_ = false;
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
		assistantAccum_ = AssistantAccum.init;
		assistantAccumActive_ = false;
		activeTurnNamespace_ = to!string(++turnNamespaceCounter_);
		expectedUserMessages ~= new ExpectedUserMessage(submission);

		PromptParams params;
		params.sessionId = sessionId_;
		foreach (ref block; submission.content)
		{
			if (block.type == "text")
			{
				VibePromptBlock promptBlock;
				promptBlock.text = block.text;
				params.prompt ~= promptBlock;
			}
			else if (block.type == "image" && block.data.length > 0)
			{
				VibePromptBlock promptBlock;
				promptBlock.type = "image";
				promptBlock.data = block.data;
				promptBlock.mimeType = block.media_type.length > 0
					? block.media_type : "image/png";
				params.prompt ~= promptBlock;
			}
		}

		submission.epoch = submissionEpoch_;

		// Acceptance is the request reaching the agent — the same point the
		// other long-lived drivers accept (claude's stdin write, codex's
		// turn/start). Vibe's session/prompt response is the TURN BOUNDARY:
		// committing the acceptance there made the app flip the task active
		// only after the turn result had idled it (ae promises defer
		// handlers), and left the task "alive" for the whole turn where the
		// question router and restart machinery require "active" mid-turn.
		// It also delayed the user echo until after the assistant chunks.
		submission.accepted = true;
		submission.settled = true;
		submission.promise.fulfill(
			AgentSubmissionReceipt.appServerAccepted);
		try
		{
			server.sendRequest("session/prompt", toJson(params))
				.then((JsonRpcResponse response) {
					finalizeTurn(submission, response);
				}, (Exception e) {
					failTurn(submission, e.msg);
				}).ignoreResult();
		}
		catch (Exception e)
		{
			failTurn(submission, e.msg);
		}
	}

	/// Close the turn on the session/prompt response.
	private void finalizeTurn(PendingMessage submission, JsonRpcResponse response)
	{
		if (!alive_ || submission.epoch != submissionEpoch_)
			return;
		if (response.isError)
		{
			failTurn(submission, "session/prompt error: " ~ response.error.get.message);
			return;
		}
		finalizeActiveTextItem();
		finalizeAllTools();
		// Transcript writer: the turn's last assistant message completes here.
		flushAssistantLine();
		emitTurnStop();
		turnInProgress = false;
		releaseGatedUserEcho(submission);
		emitTurnResult(response);
		drainPendingMessages();
	}

	/// A turn that failed after acceptance: the submission is already
	/// committed, so surface the failure as stderr plus an errored turn
	/// result — the session itself stays alive for the next turn.
	private void failTurn(PendingMessage submission, string message)
	{
		if (!alive_ || submission.epoch != submissionEpoch_)
			return;
		removeExpectedUserMessage(submission);
		resetRejectedSubmission();
		ProcessStderrEvent errEv;
		errEv.text = message;
		emitEvent(toJson(errEv));
		emitTurnStop();
		turnInProgress = false;
		TurnResultEvent trEv;
		trEv.subtype        = "error";
		trEv.is_error       = true;
		trEv.num_turns      = 1;
		trEv.duration_ms    = 0;
		trEv.total_cost_usd = 0.0;
		trEv.result         = message;
		trEv.usage          = UsageInfo(0, 0);
		emitEvent(toJson(trEv));
		drainPendingMessages();
	}

	// ----- AgentSession interface -----

	// nativeSubmissionUuid is accepted for AgentSession interface
	// compatibility but unused: the Claude-native submission UUID registry
	// has no vibe analogue (a submission's identity is its session/prompt
	// JSON-RPC request id, and the server only supplies the UUID for
	// Claude-driver tasks anyway).
	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content,
		string correlationId = null, bool isContextBootstrap = false,
		string nativeSubmissionUuid = null)
	{
		// Extract text for the echo-correlation state (image blocks ride
		// along in content; only text feeds the echo matcher).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text")
				text ~= b.text;
			else if (b.type != "image")
				throw new Exception("Unsupported content block type for Vibe: "
					~ b.type);
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

	// ACP promptCapabilities.image — vibe stores pasted images as session
	// attachments and forwards them to the provider; the model catalog must
	// also declare supports_images (the e2e mock model does).
	@property bool supportsImages() const { return true; }

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

	// Surface a contained line-handler fault on the task it belongs to.
	// The session keeps running: the agent process is unaffected by CyDo
	// failing to translate one of its lines, and the rest of the turn is
	// still worth showing.
	void handleLineHandlerError(string source, Exception e)
	{
		import cydo.protocol : TaskDiagnosticEvent, TaskDiagnosticSeverity;

		TaskDiagnosticEvent ev;
		ev.severity = TaskDiagnosticSeverity.error;
		ev.subject = "CyDo error";
		ev.body = "Failed to process agent " ~ source ~ ": " ~ e.msg;
		emitEvent(toJson(ev), null);
	}

	void handleStartupFailure(Exception error)
	{
		rejectUnsettledMessages(error);
		// A startup failure leaves the vibe-acp child running with stdin
		// open, and nothing else will stop it: stop()/closeStdin() return
		// early once handleExit clears alive_ below. Terminate the process
		// here so a failed resume, protocol mismatch or rejected session
		// option does not leak one process per attempt.
		server.shutdown();
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
			// The persisted messages.jsonl is the transcript source of truth
			// (loaded at task reload); re-emitting replayed content here
			// would duplicate every reloaded message.
			return;
		}

		// An image prompt echoes as two chunks sharing one messageId: the
		// text, then a resource_link pointing at the persisted attachment.
		// The text completes the echo; the trailing resource_link (and any
		// replay straggler) has nothing left to accumulate against.
		if (expectedUserMessages.length == 0 || expectedUserMessages[0].done)
			return;
		auto expected = expectedUserMessages[0];
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
		// The canonical echo mirrors what CyDo submitted: image blocks ride
		// along after the text so the UI keeps the image when the pending
		// echo is replaced by the confirmed one.
		ContentBlock[] content;
		ContentBlock cb;
		cb.type = "text";
		cb.text = text;
		content ~= cb;
		foreach (ref block; submission.content)
		{
			if (block.type != "image" || block.data.length == 0)
				continue;
			ContentBlock image;
			image.type = "image";
			image.data = block.data;
			image.media_type = block.media_type;
			content ~= image;
		}
		ItemStartedEvent userEv;
		userEv.item_id = "vb-user-" ~ (messageId.length > 0 ? messageId
			: activeTurnNamespace_ ~ "-" ~ to!string(nextItemIndex++));
		userEv.item_type = "user_message";
		userEv.content = content;
		if (messageId.length > 0)
			userEv.uuid = messageId;
		userEv.correlation_id = submission.correlationId;
		auto translated = TranslatedEvent(toJson(userEv), currentRawJson_);
		translated.isContextBootstrap = submission.isContextBootstrap;
		// Persist the user line once the echo completes (buildUserEcho runs
		// exactly once per submitted message, outside replay mode).
		writeUserTranscriptLine(submission, text, messageId);
		return translated;
	}

	private void handleAgentChunk(VibeSessionUpdate update, string itemType)
	{
		// Replayed content is covered by the persisted history translation.
		if (replayMode)
			return;
		auto text = chunkText(update.content);
		// Transcript writer: group thinking + text + tool_calls of one
		// assistant LLM message into a single legacy assistant line. A new
		// base uuid starts a new message, flushing the previous one.
		auto baseUuid = assistantBaseUuid(update.messageId);
		if (assistantAccumActive_
			&& baseUuid != assistantAccum_.baseUuid)
			flushAssistantLine();
		if (!assistantAccumActive_)
		{
			assistantAccum_ = AssistantAccum.init;
			assistantAccum_.baseUuid = baseUuid;
			assistantAccumActive_ = true;
		}
		if (itemType == "text")
		{
			assistantAccum_.text ~= text;
			// The assistant-<uuid> chunk is the canonical message id.
			assistantAccum_.messageId = update.messageId;
		}
		else
		{
			assistantAccum_.thinking ~= text;
			if (assistantAccum_.messageId.length == 0)
				assistantAccum_.messageId = update.messageId;
		}
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
		// Replayed tool calls are covered by the persisted history
		// translation; their updates below no-op because the replayed call
		// was never registered in activeTools.
		if (replayMode)
			return;

		finalizeActiveTextItem();

		auto meta = parseVibeMeta(update.meta);
		auto rawToolName = meta.toolName.length > 0 ? meta.toolName : "unknown";
		auto parts = decomposeVibeToolName(rawToolName);
		string name = parts.displayName;
		auto inputJson = update.rawInput.json !is null && update.rawInput.json.length > 0
			? update.rawInput.json : "{}";

		auto id = "vb-tool-" ~ update.toolCallId;
		ToolItem tool = ToolItem(id, name, inputJson, inputJson != "{}",
			parts.vibeName, update.toolCallId);
		activeTools[update.toolCallId] = tool;

		// Transcript writer: the tool call belongs to the assistant message
		// currently accumulating (the model produced it after its text).
		if (!assistantAccumActive_)
		{
			assistantAccum_ = AssistantAccum.init;
			assistantAccum_.baseUuid = update.toolCallId;
			assistantAccumActive_ = true;
		}
		assistantAccum_.toolCalls ~= `{"id": ` ~ toJson(update.toolCallId)
			~ `, "index": ` ~ to!string(assistantAccum_.toolCalls.length)
			~ `, "type": "function", "function": {"name": ` ~ toJson(parts.vibeName)
			~ `, "arguments": ` ~ toJson(inputJson) ~ `}}`;

		ItemStartedEvent toolStartEv;
		toolStartEv.item_id   = id;
		toolStartEv.item_type = "tool_use";
		toolStartEv.name      = name;
		if (parts.toolServer.length > 0)
		{
			toolStartEv.tool_server = parts.toolServer;
			toolStartEv.tool_source = parts.toolSource;
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

		// Transcript writer: the assistant message that produced this tool
		// call is complete once its results start arriving (the model emits
		// all of a message's tool calls before any execution), so flush its
		// line before the tool-result line to keep the legacy order
		// (assistant line with tool_calls, then tool result lines).
		flushAssistantLine();

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

		// Transcript writer: persist the tool-result line.
		writeToolTranscriptLine(tool, update);

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
		// CyDo MCP tool results nest the structured payload ({tasks:[...]}
		// for Task, {status, qid, ...} for Ask/Answer) inside rawOutput's
		// `structured` field; the frontend renders subtask results and
		// question statuses from item/result.tool_result, so unwrap it to
		// the same top-level shape the other drivers deliver.
		auto structuredJson = vibeStructuredPayload(update.rawOutput);
		if (structuredJson.length > 0)
			toolResEv.tool_result = JSONFragment(structuredJson);
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

/// Decomposed vibe tool name: the UI display name, the vibe-side name
/// persisted in the transcript, and the CyDo MCP server attribution.
private struct VibeToolNameParts
{
	string displayName;  // UI name ("SwitchMode")
	string vibeName;     // transcript name ("cydo_SwitchMode")
	string toolServer;   // "cydo" for CyDo MCP tools, else ""
	string toolSource;   // "mcp" for CyDo MCP tools, else ""
}

/// Decompose a vibe tool name. vibe 2.x named CyDo's MCP tools
/// `cydo_<Tool>`; vibe 3.x's Unified Harness surfaces them as
/// `mcp_cydo.<Tool>` (programmatic group `mcp_cydo`, tool `<Tool>` —
/// verified against vibe-acp 3.0.1). Both map to display name `<Tool>`
/// with the cydo MCP server, and the transcript keeps the 2.x
/// `cydo_<Tool>` name so the history translation and the
/// interrupted-call repair are unchanged.
private static VibeToolNameParts decomposeVibeToolName(string toolName)
{
	VibeToolNameParts parts;
	parts.displayName = toolName;
	parts.vibeName = toolName;
	if (toolName.startsWith("mcp_cydo."))
	{
		parts.displayName = toolName["mcp_cydo.".length .. $];
		parts.vibeName = "cydo_" ~ parts.displayName;
		parts.toolServer = "cydo";
		parts.toolSource = "mcp";
	}
	else if (toolName.startsWith("cydo_"))
	{
		parts.displayName = toolName["cydo_".length .. $];
		parts.toolServer = "cydo";
		parts.toolSource = "mcp";
	}
	return parts;
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

/// Unwrap a CyDo MCP tool's structured payload from vibe's raw result:
/// vibe 2.x nests it under a `structured` field ({tasks:[...]} for Task,
/// {status, qid, ...} for Ask/Answer). vibe 3.x's Unified Harness drops
/// the MCP structuredContent from rawOutput; for CyDo's structured results
/// the payload rides as the result text itself (the MCP server sets
/// content[0].text to the JSON string — see McpResult.structured), so a
/// JSON-object result text is parsed back out. Empty when there is none —
/// callers leave item/result.tool_result unset so plain tools (bash etc.)
/// keep their text-only rendering.
private string vibeStructuredPayload(JSONFragment rawOutput)
{
	if (rawOutput.json.length == 0)
		return "";
	@JSONPartial static struct Probe
	{
		@JSONOptional JSONFragment structured;
	}
	try
	{
		auto probe = jsonParse!Probe(rawOutput.json);
		if (probe.structured.json !is null && probe.structured.json.length > 0
			&& probe.structured.json != "null")
			return probe.structured.json;
	}
	catch (Exception) {}
	// vibe 3.x shape: {type: "success", content: [{type: "text", text: ...}]}
	@JSONPartial static struct V3Probe
	{
		@JSONOptional string type;
		@JSONPartial static struct V3Content { string type; string text; }
		@JSONOptional V3Content[] content;
	}
	try
	{
		auto probe = jsonParse!V3Probe(rawOutput.json);
		if (probe.type == "success" && probe.content.length > 0)
			foreach (ref entry; probe.content)
			{
				if (entry.type != "text" || entry.text.length == 0
					|| entry.text[0] != '{')
					continue;
				import std.json : JSONType, parseJSON;
				try
				{
					if (parseJSON(entry.text).type == JSONType.object)
						return entry.text;
				}
				catch (Exception) {}
			}
	}
	catch (Exception) {}
	return "";
}

/// Extract plain text from a completed tool call, translating vibe 3.x's
/// turn-cancellation output to the 2.x marker the interrupted-call repair
/// rewrites (see extractToolResultTextRaw).
private string extractToolResultText(JSONFragment content, JSONFragment rawOutput)
{
	auto result = extractToolResultTextRaw(content, rawOutput);
	// vibe 3.x reports a turn-cancelled tool call as the plain output
	// "client interrupt"; vibe 2.x persisted the same interruption as a
	// `<user_cancellation>` marker. Keep the 2.x marker so the repair
	// (which rewrites that marker to the real result) works unchanged.
	if (result == "client interrupt")
		return "<user_cancellation>Tool execution interrupted by user.</user_cancellation>";
	return result;
}

/// Extract plain text from a completed tool call: the `content` array's
/// text blocks, falling back to `rawOutput` (plain string, then
/// content/detailedContent/stdout fields).
private string extractToolResultTextRaw(JSONFragment content, JSONFragment rawOutput)
{
	// Vibe wraps CyDo MCP tool outcomes as {ok, server, tool, text,
	// structured} — the content array only carries a "Ran <Tool>"
	// presentation, while the real outcome (including tool errors like
	// "Unknown question ID: ...") rides in `text`. Prefer it whenever the
	// wrapper shape is present, so errors and textual results render.
	if (rawOutput.json.length > 0)
	{
		@JSONPartial static struct McpOutcomeProbe
		{
			@JSONOptional string server;
			@JSONOptional JSONFragment text;
		}
		try
		{
			auto probe = jsonParse!McpOutcomeProbe(rawOutput.json);
			if (probe.server.length > 0 && probe.text.json !is null
				&& probe.text.json.length > 0 && probe.text.json != "null")
			{
				try
				{
					auto outcome = jsonParse!string(probe.text.json);
					if (outcome.length > 0)
						return outcome;
				}
				catch (Exception) {}
			}
		}
		catch (Exception) {}
		// vibe 3.x's Unified Harness surfaces a tool outcome as
		// {type: "success", content: [{type: "text", text: ...}], _meta} —
		// the tool result's content blocks ride in rawOutput.content. The
		// ACP content array additionally carries the tool name as a second
		// text block, so rawOutput is the cleaner source.
		@JSONPartial static struct V3OutcomeProbe
		{
			@JSONOptional string type;
			@JSONPartial static struct V3Content { string type; string text; }
			@JSONOptional V3Content[] content;
		}
		try
		{
			auto probe = jsonParse!V3OutcomeProbe(rawOutput.json);
			if (probe.type == "success" && probe.content.length > 0)
			{
				string result;
				foreach (ref entry; probe.content)
					if (entry.type == "text" && entry.text.length > 0)
					{
						if (result.length > 0)
							result ~= "\n";
						result ~= entry.text;
					}
				if (result.length > 0)
					return result;
			}
		}
		catch (Exception) {}
	}
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
	auto session = attachSession(server, tid, null, "",
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

	// With no overrides, hardcoded defaults apply: vibe 3.x's catalog
	// tiers small/medium/large to mistral-small-2603, mistral-medium-3.5,
	// and mistral-large-4 respectively.
	assert(agent.resolveModelSpec("small")
		== ModelSpec(ModelSpecFields("mistral-small-2603")));
	assert(agent.resolveModelSpec("medium")
		== ModelSpec(ModelSpecFields("mistral-medium-3.5")));
	assert(agent.resolveModelSpec("large")
		== ModelSpec(ModelSpecFields("mistral-large-4")));

	// An override replaces the default model.
	agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
	assert(agent.resolveModelSpec("large").model == "custom-model");

	// An effort-only override keeps the driver's default model.
	agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
	auto effortOnly = agent.resolveModelSpec("large");
	assert(effortOnly.model == "mistral-large-4");
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

	// An unrecognized history shape leaves the repair inert.
	assert(agent.repairInterruptedToolCall([`{"type":"tool.execution_complete"}`],
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

unittest
{
	auto agent = new VibeAgent;
	assert(agent.executableName(["CYDO_VIBE_BIN": "/opt/vibe-acp"])
		== "/opt/vibe-acp");
	assert(agent.executableName(null) == "vibe-acp");

	// The one-shot spawns vibe-acp itself (vibe 3.x removed the legacy
	// runtime, and the one-shot `vibe` CLI's app-server spawn path shells
	// out to `uv`, absent in the sandbox) — no CLI flags, no --yolo, no
	// removed harness-selection flags.
	ProcessLaunch launch; // .init: no cmdPrefix
	auto args = buildVibeOneShotArgs("vibe-acp", launch);
	assert(args == ["vibe-acp"]);
	launch.cmdPrefix = ["bwrap"];
	auto prefixed = buildVibeOneShotArgs("vibe-acp", launch);
	assert(prefixed == ["bwrap", "vibe-acp"]);
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

	// Absolute work dir: config.toml suppresses updates and telemetry
	// (the per-task model is NOT pinned here — it is applied per session
	// via the `model` config option); trusted_folders.toml trusts the
	// work dir.
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
	assert(!configToml.canFind("active_model"));
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

	// Empty model: nothing model-related is written either way (the model
	// rides the per-session config option, not config.toml).
	auto profileD = buildPath(root, "profile-d");
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.vibe, profileD);
	launch.workDir = "/test/workdir";
	config.model = null;
	config.workDir = null;
	agent.bootstrapVibeProfile(launch, config);
	assert(!readText(buildPath(profileD, "config.toml")).canFind("active_model"));

	// A work dir needing TOML escaping is written as a valid basic string.
	auto profileE = buildPath(root, "profile-e");
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.vibe, profileE);
	launch.workDir = `/test/wi"rk\dir`;
	agent.bootstrapVibeProfile(launch, config);
	assert(readText(buildPath(profileE, "trusted_folders.toml"))
		== `trusted = ["/test/wi\"rk\\dir"]` ~ "\n");

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

	// A null handoffs description is omitted, never serialized as a null
	// env value — vibe's SDK rejects non-string env values (2.25.4–2.25.8).
	SessionConfig nullHandoffs = config;
	nullHandoffs.handoffs = null;
	auto nullParams = jsonParse!NewSessionProbe(
		buildNewSessionParams(7, "/test/workdir", nullHandoffs));
	auto nullServer = nullParams.mcpServers[0];
	assert(nullServer.env.length == 5);
	foreach (entry; nullServer.env)
		assert(entry.name != "CYDO_HANDOFFS");

	// All three optional summaries null (no task type context): only the
	// mandatory entries remain on the wire.
	SessionConfig bare = SessionConfig.init;
	bare.mcpSocketPath = "/tmp/sock";
	auto bareParams = jsonParse!NewSessionProbe(
		buildNewSessionParams(8, "/test/workdir", bare));
	auto bareServer = bareParams.mcpServers[0];
	assert(bareServer.env.length == 3);
	assert(bareServer.env[0].name == "CYDO_TID");
	assert(bareServer.env[1].name == "CYDO_SOCKET");
	assert(bareServer.env[2] == EnvVariable("CYDO_INCLUDE_TOOLS", ""));
	foreach (entry; bareServer.env)
		assert(entry.value !is null);

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
	// Client fs capabilities are advertised as false: the client-side
	// fs/read_text_file and fs/write_text_file handlers are not
	// implemented, and an agent that trusted a true advertisement would
	// get method-not-found for every request.
	assert(!initParams.clientCapabilities.fs.readTextFile);
	assert(!initParams.clientCapabilities.fs.writeTextFile);
	assert(!initParams.clientCapabilities.terminal);
	assert(initParams.clientInfo.name == "cydo");
	assert(initParams.clientInfo.version_ == "0.1.0");

	string[] nativeIds;
	string[] order;
	auto session = attachSession(server, 1, null, "", "/test/workdir",
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
	// session readiness; acceptance is the prompt request reaching the agent
	// (the same point claude accepts its stdin write), so the native user
	// echo streams mid-turn — before the assistant chunks — and the
	// session/prompt response is purely the turn boundary.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 1, null, "", "/test/workdir",
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
	// The drain submitted the message; acceptance committed at request time.
	assertVibeAcceptedOnce(submission);
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

	// The native user echo streams as soon as vibe echoes the full text:
	// acceptance already committed, there is no gating on the turn boundary.
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"text","text":"pre-"}}`));
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"text","text":"ready"}}`));
	drainVibePromiseNextTicks();
	assert(emitted.length == 1, "user echo streams mid-turn");
	auto echo = jsonParse!ItemStartedEvent(emitted[0]);
	assert(echo.item_type == "user_message");
	assert(echo.correlation_id == "pre-ready-nonce");
	assert(echo.content.length == 1 && echo.content[0].text == "pre-ready");

	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"agent_message_chunk","messageId":"am1","content":{"type":"text","text":"hi there"}}`));
	assert(emitted.length == 3);
	emitted = null;

	connection.respond(promptRequest, acceptedVibeResponse(
		`{"stopReason":"end_turn","usage":{"input_tokens":11,"output_tokens":7}}`));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(submission);
	assert(emitted.length == 3);
	assert(emitted[0].canFind(`"type":"item/completed"`));
	assert(emitted[0].canFind(`"text":"hi there"`));
	assert(emitted[1].canFind(`"type":"turn/stop"`));
	assert(emitted[2].canFind(`"type":"turn/result"`));
	assert(emitted[2].canFind(`"input_tokens":11`));
	assert(emitted[2].canFind(`"output_tokens":7`));
	assert(emitted[2].canFind(`"result":"hi there"`));
}

unittest
{
	// Image prompts: image ContentBlocks map onto ACP image prompt blocks
	// (base64 data + mimeType), the confirmed user echo keeps the image
	// alongside the text, and vibe's trailing resource_link chunk (the
	// persisted-attachment echo sharing the text chunk's messageId) is a
	// no-op once the echo completed.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 1, null, "", "/test/workdir",
		SessionConfig.init);
	assert(session.supportsImages);
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto image = ContentBlock("image", null);
	image.data = "aW1hZ2UtZGF0YQ==";
	image.media_type = "image/png";
	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "describe this image"),
			image], "img-nonce"));
	assertVibePending(submission);

	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"native-vibe-1"}`));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(submission);
	emitted = null;

	auto promptRequest = connection.takeRequest("session/prompt");
	auto promptParams = jsonParse!PromptParams(toJson(promptRequest.params));
	assert(promptParams.prompt.length == 2);
	assert(promptParams.prompt[0].type == "text"
		&& promptParams.prompt[0].text == "describe this image");
	assert(promptParams.prompt[1].type == "image");
	assert(promptParams.prompt[1].data == "aW1hZ2UtZGF0YQ==");
	assert(promptParams.prompt[1].mimeType == "image/png");

	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"text","text":"describe this image"}}`));
	drainVibePromiseNextTicks();
	assert(emitted.length == 1);
	auto echo = jsonParse!ItemStartedEvent(emitted[0]);
	assert(echo.item_type == "user_message");
	assert(echo.content.length == 2);
	assert(echo.content[0].type == "text"
		&& echo.content[0].text == "describe this image");
	assert(echo.content[1].type == "image"
		&& echo.content[1].data == "aW1hZ2UtZGF0YQ=="
		&& echo.content[1].media_type == "image/png");

	// The resource_link echo arrives after the text completed the echo; the
	// queue is empty and it must neither crash nor emit anything.
	emitted = null;
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"resource_link","uri":"/tmp/attach.png","name":"pasted-image.png","mimeType":"image/png"}}`));
	drainVibePromiseNextTicks();
	assert(emitted.length == 0);

	connection.respond(promptRequest, acceptedVibeResponse(
		`{"stopReason":"end_turn","usage":{"input_tokens":5,"output_tokens":5}}`));
	drainVibePromiseNextTicks();
}

unittest
{
	// Transcript writer (vibe 3.x stores sessions in the unified chunked
	// store, which has no messages.jsonl): the driver keeps its own
	// legacy-shaped transcript per session, written from the live ACP
	// stream, so the history pipeline (live watch, fork, undo) works
	// unchanged. A full turn — user echo, thinking + text, a tool call
	// with its result, and a final text — lands as user/assistant/tool
	// lines that the persisted translator reads back.
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.string : lineSplitter;
	import cydo.runtime.config : AgentDriver;

	auto profileRoot = buildPath(tempDir(), "cydo-vibe-transcript");
	if (exists(profileRoot))
		rmdirRecurse(profileRoot);
	mkdirRecurse(profileRoot);
	scope (exit)
		if (exists(profileRoot))
			rmdirRecurse(profileRoot);
	auto profile = NativeHistoryProfile(AgentDriver.vibe, profileRoot);

	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 1, null, "", "/test/workdir",
		SessionConfig.init, profile);
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "list files")], "nonce-1"));
	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"native-vibe-1"}`));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(submission);
	auto promptRequest = connection.takeRequest("session/prompt");

	// User echo completes the user line.
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"user_message_chunk","messageId":"um1","content":{"type":"text","text":"list files"}}`));
	drainVibePromiseNextTicks();
	// Thinking + text of the first assistant message, then its tool call.
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"agent_thought_chunk","messageId":"reasoning-uuid1-0","content":{"type":"text","text":"let me think"}}`));
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"agent_message_chunk","messageId":"assistant-uuid1","content":{"type":"text","text":"I will run ls"}}`));
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"tool_call","toolCallId":"call_1","rawInput":{"command":"ls"},"_meta":{"tool_name":"bash"}}`));
	// The tool result lands as a tool line.
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","content":[{"content":{"text":"file.txt"}}],"rawOutput":{"stdout":"file.txt"}}`));
	// A second assistant message (new base uuid) flushes the first line.
	connection.receive(vibeUpdate("native-vibe-1",
		`{"sessionUpdate":"agent_message_chunk","messageId":"assistant-uuid2","content":{"type":"text","text":"Done."}}`));
	// Turn end flushes the second assistant line.
	connection.respond(promptRequest, acceptedVibeResponse(
		`{"stopReason":"end_turn","usage":{"input_tokens":11,"output_tokens":7}}`));
	drainVibePromiseNextTicks();

	// The transcript resolves through the agent's historyPath scan.
	auto agent = new VibeAgent;
	auto path = agent.historyPath("native-vibe-1", profile);
	assert(path !is null, "transcript file must resolve via historyPath");
	assert(path.canFind("session_") && path.canFind("native-v"));

	string[] lines;
	foreach (line; readText(path).lineSplitter)
		if (line.length > 0)
			lines ~= line;
	assert(lines.length == 4, "expected user + 2 assistant + tool lines, got "
		~ to!string(lines.length));

	// Line 1: the user line, keyed by the vibe user message id.
	@JSONPartial static struct RoleProbe { string role; string content; string message_id; }
	auto userLine = jsonParse!RoleProbe(lines[0]);
	assert(userLine.role == "user");
	assert(userLine.content == "list files");
	assert(userLine.message_id == "um1");

	// Line 2: the first assistant message groups thinking + text + the
	// tool call into one line (the persisted translator synthesizes
	// turn/result only for a plain-content line).
	@JSONPartial static struct AssistantProbe
	{
		string role;
		@JSONOptional string content;
		@JSONOptional string reasoning_content;
		@JSONOptional JSONFragment tool_calls;
		string message_id;
	}
	auto firstAssistant = jsonParse!AssistantProbe(lines[1]);
	assert(firstAssistant.role == "assistant");
	assert(firstAssistant.content == "I will run ls");
	assert(firstAssistant.reasoning_content == "let me think");
	assert(firstAssistant.message_id == "assistant-uuid1");
	auto calls = jsonParse!(VibeHistoryToolCall[])(firstAssistant.tool_calls.json);
	assert(calls.length == 1);
	assert(calls[0].id == "call_1");
	assert(calls[0].function_.name == "bash");
	assert(calls[0].function_.arguments == `{"command":"ls"}`);

	// Line 3: the tool result line pairs with the tool call id.
	@JSONPartial static struct ToolProbe
	{
		string role;
		string content;
		string name;
		string tool_call_id;
	}
	auto toolLine = jsonParse!ToolProbe(lines[2]);
	assert(toolLine.role == "tool");
	assert(toolLine.tool_call_id == "call_1");
	assert(toolLine.name == "bash");
	assert(toolLine.content.canFind("file.txt"));

	// Line 4: the final assistant message (plain content closes the turn).
	auto lastAssistant = jsonParse!AssistantProbe(lines[3]);
	assert(lastAssistant.role == "assistant");
	assert(lastAssistant.content == "Done.");
	assert(lastAssistant.message_id == "assistant-uuid2");

	// The written lines round-trip through the persisted translator.
	auto translated = agent.translateHistoryLine(lines[0], 1, path);
	assert(translated.length == 1);
	auto userItem = jsonParse!ItemStartedEvent(translated[0].translated);
	assert(userItem.item_type == "user_message" && userItem.uuid == "um1");
	auto assistantTranslated = agent.translateHistoryLine(lines[3], 4, path);
	assert(assistantTranslated.length == 4);
	assert(jsonParse!TurnResultEvent(assistantTranslated[3].translated).result
		== "Done.");
}

unittest
{
	// assistantBaseUuid groups the reasoning-/assistant- chunk messageIds
	// of one LLM message.
	assert(VibeSession.assistantBaseUuid("assistant-422227e6-5ee1-539c-8689-679e658b595f")
		== "422227e6-5ee1-539c-8689-679e658b595f");
	assert(VibeSession.assistantBaseUuid("reasoning-422227e6-5ee1-539c-8689-679e658b595f-0")
		== "422227e6-5ee1-539c-8689-679e658b595f");
	assert(VibeSession.assistantBaseUuid("plain-id") == "plain-id");
}

unittest
{
	// A line-handler fault contained by AgentProcess reaches the session
	// as a task diagnostic and keeps the session alive (mirrors the
	// Claude driver's reportLineHandlerError wiring).
	import std.algorithm : canFind;

	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 1, null, "", "/test/workdir",
		SessionConfig.init);
	assert(session.alive);
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	session.handleLineHandlerError("stdout", new Exception("bad line"));

	assert(emitted.length == 1);
	@JSONPartial static struct DiagnosticProbe
	{
		string type;
		string severity;
		string subject;
		string body;
	}
	auto probe = jsonParse!DiagnosticProbe(emitted[0]);
	assert(probe.type == "cydo/task_diagnostic");
	assert(probe.severity == "error");
	assert(probe.subject == "CyDo error");
	assert(probe.body.canFind("stdout") && probe.body.canFind("bad line"));
	assert(session.alive);
}

unittest
{
	// A failed session/prompt turn surfaces as stderr plus an errored turn
	// result (acceptance already committed at request time), restores the
	// idle state, and immediately submits the queued successor with a
	// distinct request id.
	auto fixture = makeReadyVibeSession(2);
	auto session = fixture.session;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto rejected = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "reject me")], "reject"));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(rejected);
	auto rejectedRequest = fixture.connection.takeRequest("session/prompt");
	auto successor = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "accept me")], "successor"));
	assertVibePending(successor);
	assert(session.pendingMessages.length == 1);

	fixture.connection.respond(rejectedRequest,
		rejectedVibeResponse("prompt rejected"));
	drainVibePromiseNextTicks();
	assertVibeAcceptedOnce(rejected);
	// The failed turn's drain submitted the successor; it was accepted at
	// its own request time.
	assertVibeAcceptedOnce(successor);
	assert(session.pendingMessages.length == 0
		&& session.expectedUserMessages.length == 1
		&& session.turnInProgress);
	assert(emitted.length == 3,
		"the failed turn surfaces as stderr, stop and errored result: "
			~ to!string(emitted.length));
	assert(emitted[0].canFind(`"type":"process/stderr"`));
	assert(emitted[0].canFind("session/prompt error: prompt rejected"));
	assert(emitted[1].canFind(`"type":"turn/stop"`));
	assert(emitted[2].canFind(`"type":"turn/result"`));
	assert(emitted[2].canFind(`"subtype":"error"`));
	assert(emitted[2].canFind(`"is_error":true`));

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
	assertVibeAcceptedOnce(successor);
	assert(emitted.length == 5,
		"the session/prompt response is the vibe turn boundary");
	assert(emitted[3].canFind(`"type":"turn/stop"`));
	assert(emitted[4].canFind(`"type":"turn/result"`));
	assert(emitted[4].canFind(`"subtype":"success"`));
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
		// The in-flight submission was accepted at request time; the queued
		// one was never submitted and rejects.
		assertVibeAcceptedOnce(inFlight);
		assertVibeRejectedOnce(queued);
		assert(session.alive_ == remainsAlive);
		assert(session.expectedUserMessages.length == 0
			&& session.pendingMessages.length == 0);

		fixture.connection.respond(captured,
			acceptedVibeResponse(`{"stopReason":"end_turn"}`));
		drainVibePromiseNextTicks();
		assertVibeAcceptedOnce(inFlight);
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
		// The in-flight submission was accepted at request time — the exit
		// does not withdraw it; the queued one rejects.
		assertVibeAcceptedOnce(inFlight);
		assertVibeRejectedOnce(queued);
		assert(exitStatuses == [expectedExitStatus]);
		assert(fixture.server.dead && !session.alive);

		fixture.connection.respond(captured,
			acceptedVibeResponse(`{"stopReason":"end_turn"}`));
		drainVibePromiseNextTicks();
		assertVibeAcceptedOnce(inFlight);
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
	auto session = attachSession(server, 5, null, "", "/test/workdir",
		SessionConfig.init);
	auto queued = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "wait for initialize")],
			"init-queued"));
	assertVibePending(queued);

	connection.respond(initRequest, rejectedVibeResponse("initialize rejected"));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(queued, "initialize rejected");
	// The startup failure must terminate the process (the test double
	// records shutdown; the real shutdown would close stdin, terminate
	// and SIGKILL after a timeout) instead of leaking it with stdin open.
	assert(server.shutdownCount == 1);
	assert(server.state == VibeAcpProcess.State.failed && server.dead);
	assert(!session.alive_);

	session.handleStartupFailure(
		new Exception("duplicate initialize failure"));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(queued, "initialize rejected");
}

unittest
{
	// Per-session options: the resolved model rides the `model` config
	// option before the `thinking` (effort) option, and the session only
	// becomes ready once both are accepted.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	SessionConfig config;
	config.effort = "low";
	auto session = attachSession(server, 21, null, "mock-model",
		"/test/workdir", config);
	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"native-vibe-21"}`));
	drainVibePromiseNextTicks();
	assert(!session.sessionReady_);

	auto modelRequest = connection.takeRequest("session/set_config_option");
	auto modelParams = jsonParse!SetConfigOptionParams(
		toJson(modelRequest.params));
	assert(modelParams.sessionId == "native-vibe-21");
	assert(modelParams.configId == "model"
		&& modelParams.value == "mock-model");
	connection.respond(modelRequest, acceptedVibeResponse());
	drainVibePromiseNextTicks();
	assert(!session.sessionReady_);

	auto thinkingRequest = connection.takeRequest("session/set_config_option");
	auto thinkingParams = jsonParse!SetConfigOptionParams(
		toJson(thinkingRequest.params));
	assert(thinkingParams.configId == "thinking"
		&& thinkingParams.value == "low");
	connection.respond(thinkingRequest, acceptedVibeResponse());
	drainVibePromiseNextTicks();
	assert(session.sessionReady_ && session.alive_);

	// An empty model skips the option entirely (vibe's configured default
	// applies) and only the effort option is sent.
	auto connection2 = new TestVibeConnection;
	auto server2 = makeTestVibeAcpProcess(connection2);
	auto session2 = attachSession(server2, 22, null, "",
		"/test/workdir", config);
	auto newRequest2 = connection2.takeRequest("session/new");
	connection2.respond(newRequest2,
		acceptedVibeResponse(`{"sessionId":"native-vibe-22"}`));
	drainVibePromiseNextTicks();
	auto effortRequest = connection2.takeRequest("session/set_config_option");
	auto effortParams = jsonParse!SetConfigOptionParams(
		toJson(effortRequest.params));
	assert(effortParams.configId == "thinking");
	connection2.respond(effortRequest, acceptedVibeResponse());
	drainVibePromiseNextTicks();
	assert(session2.sessionReady_);
}

unittest
{
	// A rejected session option fails the startup and terminates the
	// process instead of leaking it.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 23, null, "nonexistent-model",
		"/test/workdir", SessionConfig.init);
	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"native-vibe-23"}`));
	drainVibePromiseNextTicks();
	auto modelRequest = connection.takeRequest("session/set_config_option");
	connection.respond(modelRequest,
		rejectedVibeResponse("Unsupported config option"));
	drainVibePromiseNextTicks();
	assert(!session.alive_ && !session.sessionReady_);
	assert(server.shutdownCount == 1);
}

unittest
{
	// The unsandboxed one-shot env carries the provider reachability
	// passthrough keys and the title-generation suppression.
	import std.process : environment;

	environment["NO_PROXY"] = "vibe-one-shot-env-test";
	scope (exit)
		environment.remove("NO_PROXY");
	auto env = buildVibeOneShotEnv();
	assert(env["NO_PROXY"] == "vibe-one-shot-env-test");
	assert(env["VIBE_SESSION_LOGGING__GENERATE_TITLES"] == "false");
	assert("PATH" in env && "HOME" in env);
}

unittest
{
	// The one-shot no-tools override denies the mutating built-in tools via
	// a per-child VIBE_TOOLS env override (vibe 3.x has no config-level way
	// to disable the built-in harness tools).
	import std.json : JSONType, parseJSON;

	auto value = parseJSON(vibeOneShotNoToolsJson);
	assert(value.type == JSONType.object);
	foreach (tool; ["bash", "read_file", "write_file", "edit", "skill"])
	{
		auto entry = tool in value.object;
		assert(entry !is null && entry.type == JSONType.object);
		auto permission = "permission" in entry.object;
		assert(permission !is null && permission.type == JSONType.string);
		assert(permission.str == "never");
	}
}

unittest
{
	// vibe 3.x tool names: the Unified Harness surfaces CyDo's MCP tools as
	// `mcp_cydo.<Tool>`; both that and the 2.x `cydo_<Tool>` name decompose
	// to the same display name, server attribution, and transcript name.
	auto v3 = decomposeVibeToolName("mcp_cydo.SwitchMode");
	assert(v3.displayName == "SwitchMode");
	assert(v3.vibeName == "cydo_SwitchMode");
	assert(v3.toolServer == "cydo" && v3.toolSource == "mcp");

	auto v2 = decomposeVibeToolName("cydo_Task");
	assert(v2.displayName == "Task");
	assert(v2.vibeName == "cydo_Task");
	assert(v2.toolServer == "cydo" && v2.toolSource == "mcp");

	auto builtin = decomposeVibeToolName("bash");
	assert(builtin.displayName == "bash");
	assert(builtin.vibeName == "bash");
	assert(builtin.toolServer.length == 0 && builtin.toolSource.length == 0);
}

unittest
{
	// vibe 3.x tool results: the MCP outcome rides in rawOutput as
	// {type: "success", content: [{type: "text", text: ...}]} — the ACP
	// content array's second block (the tool name) must not leak into the
	// result text. A turn-cancelled call ("client interrupt") translates to
	// the 2.x `<user_cancellation>` marker the repair rewrites.
	auto raw = JSONFragment(
		`{"type":"success","content":[{"type":"text","text":"Mode switch to 'plan' accepted."}],"_meta":{}}`);
	auto content = JSONFragment(
		`[{"type":"content","content":{"type":"text","text":"Mode switch to 'plan' accepted."}},` ~
		`{"type":"content","content":{"type":"text","text":"mcp_cydo.SwitchMode"}}]`);
	assert(extractToolResultText(content, raw)
		== "Mode switch to 'plan' accepted.");

	auto cancelledRaw = JSONFragment(`"client interrupt"`);
	auto cancelledContent = JSONFragment(
		`[{"type":"content","content":{"type":"text","text":"client interrupt"}}]`);
	assert(extractToolResultText(cancelledContent, cancelledRaw)
		== "<user_cancellation>Tool execution interrupted by user.</user_cancellation>");
}

unittest
{
	// vibe 3.x drops the MCP structuredContent from rawOutput; a JSON-object
	// result text is the structured payload (McpResult.structured sets
	// content[0].text to the JSON string). Plain text stays unstructured.
	auto structured = JSONFragment(
		`{"type":"success","content":[{"type":"text","text":"{\"tasks\":[{\"id\":7}]}"}],"_meta":{}}`);
	assert(vibeStructuredPayload(structured) == `{"tasks":[{"id":7}]}`);

	auto plain = JSONFragment(
		`{"type":"success","content":[{"type":"text","text":"Mode switch accepted."}],"_meta":{}}`);
	assert(vibeStructuredPayload(plain) == "");

	// The 2.x {structured: ...} wrapper still wins when present.
	auto legacy = JSONFragment(`{"ok":true,"server":"cydo","tool":"Task","text":"x","structured":{"tasks":[]}}`);
	assert(vibeStructuredPayload(legacy) == `{"tasks":[]}`);
}

unittest
{
	// The ACP one-shot: initialize → session/new (no MCP servers) →
	// session/set_mode "ask" (the no-tools guard) → session/set_config_option
	// model → session/prompt; assistant text chunks accumulate into the
	// result, and every permission request is denied.
	auto connection = new TestVibeConnection;
	auto promise = new Promise!string;
	string result;
	bool rejected;
	promise.then((string text) { result = text; })
		.except((Exception) { rejected = true; })
		.ignoreResult();
	auto oneShot = new VibeOneShotAcp(connection, "mock", "title this",
		promise);

	auto initReq = connection.takeRequest("initialize");
	connection.respond(initReq, JsonRpcResponse.success(initReq.id,
		jsonParse!SO(`{"protocolVersion":1}`)));
	drainVibePromiseNextTicks();

	auto newReq = connection.takeRequest("session/new");
	auto newParams = newReq.params.deserializeTo!NewSessionParams();
	assert(newParams.mcpServers is null || newParams.mcpServers.length == 0);
	connection.respond(newReq, JsonRpcResponse.success(newReq.id,
		jsonParse!SO(`{"sessionId":"oneshot-1"}`)));
	drainVibePromiseNextTicks();

	auto modeReq = connection.takeRequest("session/set_mode");
	auto modeParams = modeReq.params.deserializeTo!SetModeParams();
	assert(modeParams.sessionId == "oneshot-1" && modeParams.modeId == "ask");
	connection.respond(modeReq, JsonRpcResponse.success(modeReq.id,
		jsonParse!SO(`{}`)));
	drainVibePromiseNextTicks();

	auto modelReq = connection.takeRequest("session/set_config_option");
	auto modelParams = modelReq.params.deserializeTo!SetConfigOptionParams();
	assert(modelParams.configId == "model" && modelParams.value == "mock");
	connection.respond(modelReq, JsonRpcResponse.success(modelReq.id,
		jsonParse!SO(`{}`)));
	drainVibePromiseNextTicks();

	auto promptReq = connection.takeRequest("session/prompt");
	// Assistant text arrives in chunks before the prompt response.
	connection.receive(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"oneshot-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"A "},"messageId":"m1"}}}`);
	connection.receive(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"oneshot-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Title"},"messageId":"m1"}}}`);
	// A permission request mid-turn is denied (the no-tools guard).
	connection.receive(`{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"oneshot-1","toolCall":{"toolCallId":"t1"}}}`);
	drainVibePromiseNextTicks();
	auto permResp = jsonParse!JsonRpcResponse(connection.sentMessages[0]);
	connection.sentMessages = connection.sentMessages[1 .. $];
	assert(permResp.id && toJson(permResp.id) == "99");
	assert(!permResp.isError);
	auto outcome = permResp.result.deserializeTo!PermissionOutcome();
	assert(outcome.outcome.outcome == "cancelled");

	connection.respond(promptReq, JsonRpcResponse.success(promptReq.id,
		jsonParse!SO(`{"stopReason":"end_turn"}`)));
	drainVibePromiseNextTicks();
	assert(!rejected);
	assert(result == "A Title");
}

unittest
{
	// The interrupted-tool-call repair rewrites the persisted user-
	// cancellation tool record to the intended result.
	auto agent = new VibeAgent;
	auto call = `{"role": "assistant", "injected": false, "message_id": "a1", "tool_calls": [{"id": "call_1", "index": 0, "type": "function", "function": {"name": "cydo_SwitchMode", "arguments": "{\"mode\":\"write\"}"}}]}`;
	auto cancelled = `{"role": "tool", "content": "<user_cancellation>Tool execution interrupted by user.</user_cancellation>", "injected": false, "name": "cydo_SwitchMode", "tool_call_id": "call_1"}`;
	auto user = `{"role": "user", "content": "call switchmode write", "injected": false, "message_id": "u1"}`;

	auto repaired = agent.repairInterruptedToolCall(
		[user, call, cancelled], "mcp__cydo__SwitchMode",
		"Mode switch to 'write' successful.");
	assert(repaired !is null);
	assert(repaired.lines.length == 3);
	assert(repaired.lines[0] == user && repaired.lines[1] == call);
	assert(repaired.lines[2].canFind("Mode switch to 'write' successful."));
	assert(!repaired.lines[2].canFind("<user_cancellation>"));

	// A result recorded before the interrupt carries the success text
	// already: no cancellation marker, nothing to repair.
	auto settled = `{"role": "tool", "content": "Mode switch to 'write' successful.", "injected": false, "name": "cydo_SwitchMode", "tool_call_id": "call_1"}`;
	assert(agent.repairInterruptedToolCall([user, call, settled],
		"mcp__cydo__SwitchMode", "x") is null);

	// No matching tool call leaves the file untouched.
	assert(agent.repairInterruptedToolCall([user, cancelled],
		"mcp__cydo__SwitchMode", "x") is null);
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
		auto session = attachSession(server, 6, resumeSessionId, "",
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
		// The failed setup must have terminated the process.
		assert(server.shutdownCount == 1);
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
	// session/load replay: content arriving before the response is consumed
	// silently — the persisted messages.jsonl translation is the transcript
	// source of truth and re-emitting replayed content would duplicate it.
	// The response ends replay mode and emits the synthetic session/init.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	auto session = attachSession(server, 8, "native-vibe-8", "",
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
	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"agent_message_chunk","messageId":"replay-m2","content":{"type":"text","text":"earlier answer"}}`));
	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"tool_call","toolCallId":"replay-t1","rawInput":{"command":"ls"},"_meta":{"tool_name":"bash"}}`));
	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"tool_call_update","toolCallId":"replay-t1","status":"completed","rawOutput":"done"}}`));
	assert(emitted.length == 0);

	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"tool_call","toolCallId":"checkpoint:resume:0","_meta":{"tool_name":"think"}}`));
	assert(emitted.length == 0);

	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"tool_call","toolCallId":"replay-compact","_meta":{"tool_name":"think","checkpoint_kind":"compaction"}}`));
	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"tool_call_update","toolCallId":"replay-compact","status":"completed","_meta":{"tool_name":"think","checkpoint_kind":"compaction"}}`));
	// The compaction pair is the one replay event that survives: the compact
	// boundary exists only on the wire, not in the source dir's messages.jsonl.
	assert(emitted.length == 1
		&& emitted[0].canFind(`"type":"session/compacted"`));

	connection.respond(loadRequest, acceptedVibeResponse());
	drainVibePromiseNextTicks();
	assert(!session.replayMode && session.sessionReady_);
	assert(emitted.length == 2 && emitted[1].canFind(`"type":"session/init"`));

	// Live content after the response streams normally.
	emitted = null;
	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "next turn")], "replay-nonce"));
	auto promptRequest = connection.takeRequest("session/prompt");
	connection.receive(vibeUpdate("native-vibe-8",
		`{"sessionUpdate":"agent_message_chunk","messageId":"live-m1","content":{"type":"text","text":"next answer"}}`));
	assert(emitted.length >= 2);
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
	// Vibe requires the nested {outcome: {...}} response shape.
	assert(fixture.connection.sentMessages[0].canFind(
		`"outcome":{"outcome":"selected","optionId":"allow_once"}}`));

	fixture.connection.receive(`{"jsonrpc":"2.0","id":102,"method":"session/request_permission","params":{"sessionId":"no-such-session","toolCall":{"toolCallId":"t9"}}}`);
	drainVibePromiseNextTicks();
	assert(fixture.connection.sentMessages.length == 2);
	assert(fixture.connection.sentMessages[1].canFind(
		`"outcome":{"outcome":"cancelled"}}`));
	assert(!fixture.connection.sentMessages[1].canFind(`"optionId"`));

	fixture.connection.receive(vibeUpdate("no-such-session",
		`{"sessionUpdate":"agent_message_chunk","messageId":"x","content":{"type":"text","text":"orphan"}}`));
	drainVibePromiseNextTicks();
	assert(emitted.length == 0);
	assert(fixture.connection.sentMessages.length == 2);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto root = buildPath(tempDir(), "cydo-vibe-history-path");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto agent = new VibeAgent;
	auto profile = NativeHistoryProfile(AgentDriver.vibe,
		buildPath(root, "home", ".vibe"));

	// No sessions dir yet: no path.
	assert(agent.historyPath("abcd1234abcd1234", profile) is null);

	auto sessionsDir = buildPath(profile.root, "logs", "session");
	mkdirRecurse(buildPath(sessionsDir, "session_20260101_010101_abcd1234"));
	mkdirRecurse(buildPath(sessionsDir, "session_20260102_020202_abcd1234"));
	mkdirRecurse(buildPath(sessionsDir, "session_20260103_030303_99999999"));

	// Older dir without the file: not a candidate yet.
	assert(agent.historyPath("abcd1234abcd1234", profile) is null);

	write(buildPath(sessionsDir, "session_20260101_010101_abcd1234",
		"messages.jsonl"), "{}\n");
	auto resolved = agent.historyPath("abcd1234abcd1234", profile);
	assert(resolved.canFind("session_20260101_010101_abcd1234"),
		resolved);

	// Newest matching dir wins (fork/compaction chains).
	write(buildPath(sessionsDir, "session_20260102_020202_abcd1234",
		"messages.jsonl"), "{}\n");
	resolved = agent.historyPath("abcd1234abcd1234", profile);
	assert(resolved.canFind("session_20260102_020202_abcd1234"), resolved);

	// A different session id resolves to its own dir.
	write(buildPath(sessionsDir, "session_20260103_030303_99999999",
		"messages.jsonl"), "{}\n");
	assert(agent.historyPath("99999999eeeeeeee", profile).canFind(
		"session_20260103_030303_99999999"));

	// Short ids never resolve.
	assert(agent.historyPath("short", profile) is null);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto root = buildPath(tempDir(), "cydo-vibe-discard-unified");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto agent = new VibeAgent;
	auto profile = NativeHistoryProfile(AgentDriver.vibe,
		buildPath(root, "home", ".vibe"));
	auto sessionsDir = buildPath(profile.root, "logs", "session");
	auto unifiedDir = buildPath(sessionsDir, "unified");
	auto sessionId = "abcd1234abcd1234";
	auto storeDir = buildPath(unifiedDir, sessionId);
	auto otherStoreDir = buildPath(unifiedDir, "99999999eeeeeeee");

	// No transcript: vibe's store is the only copy and must be kept.
	mkdirRecurse(buildPath(storeDir, "generations"));
	write(buildPath(storeDir, "CURRENT"), "{}");
	agent.discardUnifiedStoreForResume(sessionId, profile);
	assert(exists(buildPath(storeDir, "CURRENT")));

	// Transcript present: the store is discarded so session/load imports
	// the driver-written transcript instead.
	mkdirRecurse(buildPath(sessionsDir, "session_20260101_010101_abcd1234"));
	write(buildPath(sessionsDir, "session_20260101_010101_abcd1234",
		"messages.jsonl"), "{}\n");
	mkdirRecurse(buildPath(otherStoreDir, "generations"));
	write(buildPath(otherStoreDir, "CURRENT"), "{}");
	agent.discardUnifiedStoreForResume(sessionId, profile);
	assert(!exists(storeDir));
	// Other sessions' stores are untouched.
	assert(exists(buildPath(otherStoreDir, "CURRENT")));

	// Transcript present but no store: a no-op, not an error.
	agent.discardUnifiedStoreForResume(sessionId, profile);

	// Empty profile root: a no-op.
	auto emptyProfile = NativeHistoryProfile.init;
	agent.discardUnifiedStoreForResume(sessionId, emptyProfile);
	agent.discardUnifiedStoreForResume(null, profile);
}

unittest
{
	// History translation (Part 4): persisted LLM-message lines map to the
	// same agnostic shapes the live session emits.
	auto agent = new VibeAgent;

	// A user line becomes one user_message item keyed by the persisted
	// message_id.
	auto user = agent.translateHistoryLine(
		`{"role": "user", "content": "run command echo hi", "injected": false, "message_id": "u1"}`, 3);
	assert(user.length == 1);
	auto userItem = jsonParse!ItemStartedEvent(user[0].translated);
	assert(userItem.item_type == "user_message");
	assert(userItem.item_id == "vb-hist-user-u1");
	assert(userItem.uuid == "u1");
	assert(userItem.content.length == 1
		&& userItem.content[0].text == "run command echo hi");
	assert(user[0].raw.canFind("\"message_id\": \"u1\""));

	// A user line with persisted images inlines the session attachment file
	// back as a base64 image block; a missing attachment degrades to the
	// text-only message.
	{
		import std.base64 : Base64;
		import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
		import std.path : buildPath;

		auto attDir = buildPath(tempDir(), "cydo-vibe-hist-image");
		if (exists(attDir))
			rmdirRecurse(attDir);
		mkdirRecurse(attDir);
		scope (exit)
			if (exists(attDir))
				rmdirRecurse(attDir);
		auto attPath = buildPath(attDir, "attach.png");
		auto bytes = cast(ubyte[]) "png-bytes";
		write(attPath, bytes);
		auto expectedB64 = cast(string) Base64.encode(bytes);
		auto historyPath = buildPath(attDir, "messages.jsonl");

		auto withImage = agent.translateHistoryLine(
			`{"role": "user", "content": "describe this image", "injected": false, "message_id": "u2", "images": [{"source": {"kind": "file", "path": "` ~ attPath ~ `"}, "alias": "pasted-image.png", "mime_type": "image/png"}]}`, 4,
			historyPath);
		assert(withImage.length == 1);
		auto imageItem = jsonParse!ItemStartedEvent(withImage[0].translated);
		assert(imageItem.content.length == 2);
		assert(imageItem.content[0].type == "text"
			&& imageItem.content[0].text == "describe this image");
		assert(imageItem.content[1].type == "image"
			&& imageItem.content[1].data == expectedB64
			&& imageItem.content[1].media_type == "image/png");

		// A missing attachment degrades to the text-only message.
		auto missing = agent.translateHistoryLine(
			`{"role": "user", "content": "describe this image", "injected": false, "message_id": "u3", "images": [{"source": {"kind": "file", "path": "` ~ buildPath(attDir, "gone.png") ~ `"}, "mime_type": "image/png"}]}`, 5,
			historyPath);
		assert(missing.length == 1);
		auto missingItem = jsonParse!ItemStartedEvent(missing[0].translated);
		assert(missingItem.content.length == 1
			&& missingItem.content[0].type == "text");

		// A path outside the session dir is never read — the backend is
		// unsandboxed and a crafted history line must not be able to make
		// it read arbitrary host files.
		auto outsideDir = buildPath(tempDir(), "cydo-vibe-hist-image-outside");
		if (exists(outsideDir))
			rmdirRecurse(outsideDir);
		mkdirRecurse(outsideDir);
		scope (exit)
			if (exists(outsideDir))
				rmdirRecurse(outsideDir);
		auto outsidePath = buildPath(outsideDir, "secret.png");
		write(outsidePath, cast(ubyte[]) "secret");
		auto outside = agent.translateHistoryLine(
			`{"role": "user", "content": "leak this", "injected": false, "message_id": "u4", "images": [{"source": {"kind": "file", "path": "` ~ outsidePath ~ `"}, "mime_type": "image/png"}]}`, 6,
			historyPath);
		assert(outside.length == 1);
		auto outsideItem = jsonParse!ItemStartedEvent(outside[0].translated);
		assert(outsideItem.content.length == 1
			&& outsideItem.content[0].type == "text");

		// No history path (tail-side translation without a resolved file)
		// never inlines images either.
		auto unrooted = agent.translateHistoryLine(
			`{"role": "user", "content": "describe this image", "injected": false, "message_id": "u5", "images": [{"source": {"kind": "file", "path": "` ~ attPath ~ `"}, "mime_type": "image/png"}]}`, 7);
		assert(unrooted.length == 1);
		auto unrootedItem = jsonParse!ItemStartedEvent(unrooted[0].translated);
		assert(unrootedItem.content.length == 1
			&& unrootedItem.content[0].type == "text");
	}

	// Without a message_id the line number becomes the anchor.
	auto unkeyed = agent.translateHistoryLine(
		`{"role": "user", "content": "hi", "injected": false}`, 7);
	assert(unkeyed.length == 1);
	assert(jsonParse!ItemStartedEvent(unkeyed[0].translated).item_id
		== "vb-hist-user-line:7");

	// An assistant text message: thinking + text items, then the synthesized
	// turn/stop + turn/result pair that closes the turn.
	auto assistant = agent.translateHistoryLine(
		`{"role": "assistant", "content": "OK", "reasoning_content": "think first", "injected": false, "message_id": "a1"}`, 4);
	assert(assistant.length == 6);
	auto think = jsonParse!ItemStartedEvent(assistant[0].translated);
	assert(think.item_type == "thinking" && think.item_id == "vb-hist-think-a1");
	auto thinkDone = jsonParse!ItemCompletedEvent(assistant[1].translated);
	assert(thinkDone.item_id == "vb-hist-think-a1" && thinkDone.text == "think first");
	auto text = jsonParse!ItemStartedEvent(assistant[2].translated);
	assert(text.item_type == "text" && text.item_id == "vb-hist-text-a1");
	auto textDone = jsonParse!ItemCompletedEvent(assistant[3].translated);
	assert(textDone.text == "OK");
	assert(jsonParse!TurnStopEvent(assistant[4].translated).type == "turn/stop");
	auto turnResult = jsonParse!TurnResultEvent(assistant[5].translated);
	assert(turnResult.subtype == "success" && turnResult.result == "OK");

	// A tool_calls message emits tool_use items with the live naming
	// contract plus a segment-closing turn/stop (the turn itself stays
	// open: no turn/result is synthesized for a tool_calls line).
	auto toolCall = agent.translateHistoryLine(
		`{"role": "assistant", "injected": false, "message_id": "a2", "tool_calls": [{"id": "call_1", "index": 0, "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}]}`, 5);
	assert(toolCall.length == 2);
	auto toolItem = jsonParse!ItemStartedEvent(toolCall[0].translated);
	assert(toolItem.item_type == "tool_use");
	assert(toolItem.item_id == "vb-tool-call_1");
	assert(toolItem.name == "bash" && toolItem.tool_server is null);
	assert(toolItem.input.json == `{"command":"ls"}`);
	assert(jsonParse!TurnStopEvent(toolCall[1].translated).type == "turn/stop");

	// A mixed content + tool_calls line is one mid-turn segment: the text
	// items, the tool_use item, and a single segment-closing turn/stop —
	// but no turn/result, which would prematurely end the turn before
	// the tool results and the turn's real end.
	auto mixed = agent.translateHistoryLine(
		`{"role": "assistant", "content": "Let me check.", "injected": false, "message_id": "a4", "tool_calls": [{"id": "call_3", "index": 0, "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}]}`, 8);
	assert(mixed.length == 4);
	auto mixedText = jsonParse!ItemStartedEvent(mixed[0].translated);
	assert(mixedText.item_type == "text" && mixedText.item_id == "vb-hist-text-a4");
	auto mixedTextDone = jsonParse!ItemCompletedEvent(mixed[1].translated);
	assert(mixedTextDone.item_id == "vb-hist-text-a4"
		&& mixedTextDone.text == "Let me check.");
	auto mixedTool = jsonParse!ItemStartedEvent(mixed[2].translated);
	assert(mixedTool.item_type == "tool_use" && mixedTool.item_id == "vb-tool-call_3");
	assert(jsonParse!TurnStopEvent(mixed[3].translated).type == "turn/stop");
	foreach (event; mixed)
		assert(!event.translated.canFind(`"type":"turn/result"`));

	// cydo_<tool> MCP names decompose into the canonical name + server.
	auto cydoCall = agent.translateHistoryLine(
		`{"role": "assistant", "injected": false, "message_id": "a3", "tool_calls": [{"id": "call_2", "index": 0, "type": "function", "function": {"name": "cydo_SwitchMode", "arguments": "{\"mode\":\"write\"}"}}]}`, 6);
	auto cydoItem = jsonParse!ItemStartedEvent(cydoCall[0].translated);
	assert(cydoItem.name == "SwitchMode");
	assert(cydoItem.tool_server == "cydo" && cydoItem.tool_source == "mcp");

	// A tool line completes its tool_use item with a text result.
	auto toolResult = agent.translateHistoryLine(
		`{"role": "tool", "content": "stdout: done", "injected": false, "name": "bash", "tool_call_id": "call_1"}`, 7);
	assert(toolResult.length == 2);
	auto comp = jsonParse!ItemCompletedEvent(toolResult[0].translated);
	assert(comp.item_id == "vb-tool-call_1");
	auto res = jsonParse!ItemResultEvent(toolResult[1].translated);
	assert(res.item_id == "vb-tool-call_1");
	assert(jsonParse!string(res.content.json) == "stdout: done");

	// Vibe-internal (injected) records and malformed lines never translate.
	assert(agent.translateHistoryLine(
		`{"role": "user", "content": "internal", "injected": true, "message_id": "i1"}`, 8).length == 0);
	assert(agent.translateHistoryLine(`not json`, 9).length == 0);
	assert(agent.translateHistoryLine(`{"role": "system"}`, 10).length == 0);

	// Empty-content user and tool lines without an id never translate.
	assert(agent.translateHistoryLine(`{"role": "user", "content": ""}`, 11).length == 0);
	assert(agent.translateHistoryLine(`{"role": "tool", "content": "x"}`, 12).length == 0);
}

unittest
{
	// History boundaries (Part 4): persisted anchors use message_id, with the
	// Claude-style line:<n> fallback; injected records are excluded.
	auto agent = new VibeAgent;
	auto userLine = `{"role": "user", "content": "hello", "injected": false, "message_id": "u1"}`;
	auto injectedLine = `{"role": "user", "content": "internal", "injected": true, "message_id": "i1"}`;
	auto assistantLine = `{"role": "assistant", "content": "hi", "injected": false, "message_id": "a1"}`;
	auto toolLine = `{"role": "tool", "content": "out", "injected": false, "tool_call_id": "c1"}`;
	auto content = userLine ~ "\n" ~ injectedLine ~ "\n" ~ assistantLine ~ "\n"
		~ toolLine ~ "\n" ~ `{"role": "user", "content": "plain", "injected": false}` ~ "\n";
	auto boundaries = agent.extractPersistedHistoryBoundaries(content);
	assert(boundaries.length == 3);
	assert(boundaries[0] == PersistedHistoryBoundary("u1",
		PersistedHistoryBoundaryKind.user, null, 1));
	assert(boundaries[1] == PersistedHistoryBoundary("a1",
		PersistedHistoryBoundaryKind.agent_turn, null, 3));
	assert(boundaries[2].anchor == "line:5");
	assert(boundaries[2].kind == PersistedHistoryBoundaryKind.user);
	assert(boundaries[2].sourceLine == 5);

	// lineOffset shifts the source lines (used for tail re-scans).
	auto shifted = agent.extractPersistedHistoryBoundaries(content, 100);
	assert(shifted[2].anchor == "line:105");

	// Line predicates and fork anchors agree with the boundary extraction.
	assert(agent.isUserMessageLine(userLine));
	assert(!agent.isUserMessageLine(injectedLine));
	assert(!agent.isUserMessageLine(assistantLine));
	assert(agent.isAssistantMessageLine(assistantLine));
	assert(!agent.isAssistantMessageLine(toolLine));
	assert(agent.isForkableLine(userLine) && agent.isForkableLine(assistantLine));
	assert(!agent.isForkableLine(toolLine));
	assert(agent.forkIdMatchesLine(userLine, 1, "u1"));
	assert(!agent.forkIdMatchesLine(userLine, 1, "a1"));
	// line:<n> anchors match by physical line number, like Claude's.
	assert(agent.forkIdMatchesLine(userLine, 5, "line:5"));
	assert(!agent.forkIdMatchesLine(userLine, 1, "line:5"));
	assert(!agent.forkIdMatchesLine(`not json`, 1, "u1"));
}

unittest
{
	// Session discovery (Part 4): session dirs need messages.jsonl plus a
	// meta.json carrying the full resumable session ID; project matching uses
	// meta.json's origin_directory.
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto root = buildPath(tempDir(), "cydo-vibe-history-sessions");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto sessionsDir = buildPath(root, "home", ".vibe", "logs", "session");
	auto dirA = buildPath(sessionsDir, "session_20260101_010101_aaaa1111");
	mkdirRecurse(dirA);
	write(buildPath(dirA, "meta.json"),
		`{"session_id": "aaaa1111-2222-3333-4444-555566667777",` ~ "\n"
		~ ` "origin_directory": "/work/proj", "title": null, "parent_session_id": null}`);
	write(buildPath(dirA, "messages.jsonl"),
		`{"role": "user", "content": "hello vibe", "injected": false, "message_id": "m1"}` ~ "\n");
	// No messages.jsonl: not a transcript dir.
	mkdirRecurse(buildPath(sessionsDir, "session_20260102_020202_bbbb2222"));
	// No meta.json: the session ID is not resumable.
	auto dirC = buildPath(sessionsDir, "session_20260103_030303_cccc3333");
	mkdirRecurse(dirC);
	write(buildPath(dirC, "messages.jsonl"), `{"role": "user", "content": "x"}` ~ "\n");
	// A titled session with a later user message.
	auto dirD = buildPath(sessionsDir, "session_20260104_040404_dddd4444");
	mkdirRecurse(dirD);
	write(buildPath(dirD, "meta.json"),
		`{"session_id": "dddd4444-3333-2222-1111-000099998888", "origin_directory": "/work/other", "title": "Named session"}`);
	write(buildPath(dirD, "messages.jsonl"),
		`{"role": "user", "content": "second message with longer text", "injected": false}` ~ "\n");

	auto agent = new VibeAgent;
	auto profile = NativeHistoryProfile(AgentDriver.vibe,
		buildPath(root, "home", ".vibe"));
	auto sessions = agent.enumerateAllSessions(profile);
	assert(sessions.length == 2);
	// dirEntries yields filesystem order; key by session ID instead.
	DiscoveredSession[string] byId;
	foreach (ref ds; sessions)
		byId[ds.sessionId] = ds;
	assert("aaaa1111-2222-3333-4444-555566667777" in byId);
	assert("dddd4444-3333-2222-1111-000099998888" in byId);
	auto sessionA = byId["aaaa1111-2222-3333-4444-555566667777"];
	assert(sessionA.projectPath == "/work/proj");
	assert(sessionA.exactHistoryPath.canFind("messages.jsonl"));

	// meta.json's title wins; a null title falls back to the first user
	// message; origin_directory becomes the project path.
	auto metaA = agent.readSessionMeta(sessionA);
	assert(metaA.title == "hello vibe");
	assert(metaA.projectPath == "/work/proj");
	assert(metaA.hasMessages);
	auto metaD = agent.readSessionMeta(
		byId["dddd4444-3333-2222-1111-000099998888"]);
	assert(metaD.title == "Named session");
	assert(metaD.projectPath == "/work/other");
	assert(metaD.hasMessages);

	assert(agent.matchProject(sessionA, ["/work/other", "/work/proj"]) == "/work/proj");
	assert(agent.matchProject(sessionA, ["/work/other"]) == "");
	assert(agent.matchProject(sessionA, []) == "");
}

unittest
{
	// Effort mapping (Part 4, plan step 6): a configured effort applies as
	// the `thinking` config option before the session becomes ready; a
	// rejected option fails the startup.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	SessionConfig config;
	config.effort = "high";
	auto session = attachSession(server, 12, null, "",
		"/test/workdir", config);

	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};

	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"effort-session"}`));
	drainVibePromiseNextTicks();
	// Not started yet: the option request is still pending.
	assert(!session.sessionReady_);

	auto optionRequest = connection.takeRequest("session/set_config_option");
	auto optionParams = jsonParse!SetConfigOptionParams(toJson(optionRequest.params));
	assert(optionParams.sessionId == "effort-session");
	assert(optionParams.configId == "thinking");
	assert(optionParams.value == "high");
	assert(emitted.length == 0);

	connection.respond(optionRequest, acceptedVibeResponse(`{"configOptions":[]}`));
	drainVibePromiseNextTicks();
	assert(session.sessionReady_);
	assert(emitted.length == 1 && emitted[0].canFind(`"type":"session/init"`));

	// An empty effort never sends the option request (all existing tests run
	// with SessionConfig.init and no option request appears).
	auto plainFixture = makeReadyVibeSession(13);
	assert(plainFixture.session.sessionReady_);
}

unittest
{
	// Effort rejection (Part 4, plan step 6): a refused thinking option
	// fails the startup and the pending submission drains with the error.
	auto connection = new TestVibeConnection;
	auto server = makeTestVibeAcpProcess(connection);
	SessionConfig config;
	config.effort = "banana";
	auto session = attachSession(server, 14, null, "",
		"/test/workdir", config);

	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};
	auto queued = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "queued")], "queued-nonce"));
	assertVibePending(queued);

	auto newRequest = connection.takeRequest("session/new");
	connection.respond(newRequest,
		acceptedVibeResponse(`{"sessionId":"effort-fail-session"}`));
	drainVibePromiseNextTicks();
	auto optionRequest = connection.takeRequest("session/set_config_option");
	connection.respond(optionRequest,
		rejectedVibeResponse("Invalid thinking value"));
	drainVibePromiseNextTicks();
	assertVibeRejectedOnce(queued,
		"session/set_config_option error: Invalid thinking value");
	assert(!session.alive_ && !session.sessionReady_);
	assert(emitted.length == 0);
}

unittest
{
	// CyDo MCP tool results nest the structured payload under rawOutput's
	// `structured` field; item/result unwraps it so the frontend's cydo
	// tool-result renderer sees the same shape the other drivers deliver.
	import std.algorithm : filter;
	import std.array : array;

	assert(vibeStructuredPayload(JSONFragment(
			`{"ok":true,"tool":"Task","structured":{"tasks":[{"summary":"child-done","tid":2,"status":"success"}]}}`))
		== `{"tasks":[{"summary":"child-done","tid":2,"status":"success"}]}`,
		"structured payload is unwrapped to its top-level shape");
	assert(vibeStructuredPayload(JSONFragment(`{"output":{"exit_code":0}}`)) == "",
		"plain tool output has no structured payload");
	assert(vibeStructuredPayload(JSONFragment(`{"structured":null}`)) == "");
	assert(vibeStructuredPayload(JSONFragment(`not json`)) == "");
	assert(vibeStructuredPayload(JSONFragment("")) == "");

	// The live tool lifecycle attaches it to item/result.
	auto fixture = makeReadyVibeSession(15);
	auto session = fixture.session;
	auto sid = session.sessionId_;
	string[] emitted;
	session.onOutput = (TranslatedEvent event) {
		emitted ~= event.translated;
	};
	auto submission = new TestVibeSubmissionOutcome(
		session.sendMessage([ContentBlock("text", "call task research")], "task-nonce"));
	auto promptRequest = fixture.connection.takeRequest("session/prompt");
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t-task","rawInput":{"tasks":[]},"_meta":{"tool_name":"cydo_Task"}}`));
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t-task","status":"completed","content":[{"type":"content","content":{"type":"text","text":"Ran Task"}}],"rawOutput":{"ok":true,"tool":"Task","structured":{"tasks":[{"summary":"child-done","tid":2,"status":"success"}]}}}`));
	auto result = emitted
		.filter!(e => e.canFind(`"type":"item/result"`))
		.array[0];
	assert(result.canFind(`"tool_result":{"tasks":[{"summary":"child-done","tid":2,"status":"success"}]}`),
		result);
	// Plain tools keep their text-only item/result (no tool_result field).
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call","toolCallId":"t-bash","rawInput":{"command":"ls"},"_meta":{"tool_name":"bash"}}`));
	fixture.connection.receive(vibeUpdate(sid,
		`{"sessionUpdate":"tool_call_update","toolCallId":"t-bash","status":"completed","rawOutput":{"output":{"exit_code":0,"stdout":"file"}}}`));
	auto plainResult = emitted
		.filter!(e => e.canFind(`"item_id":"vb-tool-t-bash"`) && e.canFind(`"type":"item/result"`))
		.array[0];
	assert(!plainResult.canFind(`"tool_result"`), plainResult);

	// Persisted history: the tool line's nested tool_result is unwrapped on
	// reload the same way.
	auto agent = new VibeAgent;
	auto reloaded = agent.translateHistoryLine(
		`{"role": "tool", "content": "Ran Task", "injected": false, "name": "cydo_Task", "tool_call_id": "call_t", "tool_result": {"ok": true, "tool": "Task", "structured": {"tasks": [{"summary": "child-done", "tid": 2, "status": "success"}]}}}`, 21);
	assert(reloaded.length == 2);
	auto resEv = jsonParse!ItemResultEvent(reloaded[1].translated);
	assert(resEv.item_id == "vb-tool-call_t");
	assert(resEv.tool_result.json.canFind(`"tasks"`));
	assert(jsonParse!string(resEv.content.json) == "Ran Task");
}

unittest
{
	// createHistoryForkDestination: a fork gets its own session dir with a
	// meta.json carrying the forked session_id — the shape vibe's session/load
	// validates (required fields verified against 2.26.1).
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
	import std.path : baseName, buildPath, dirName;

	auto root = buildPath(tempDir(), "cydo-vibe-fork-dest");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto sessionsDir = buildPath(root, "logs", "session");
	auto sourceDir = buildPath(sessionsDir, "session_20260101_010101_aaaa1111");
	mkdirRecurse(sourceDir);
	write(buildPath(sourceDir, "meta.json"),
		`{"session_id": "aaaa1111-2222-3333-4444-555566667777",` ~ "\n"
		~ ` "origin_directory": "/work/proj", "username": "alice"}`);
	write(buildPath(sourceDir, "messages.jsonl"),
		`{"role": "user", "content": "one", "injected": false}` ~ "\n"
		~ `{"role": "assistant", "content": "two", "injected": false}` ~ "\n");

	auto agent = new VibeAgent;
	auto profile = NativeHistoryProfile(AgentDriver.vibe, root);
	auto newSessionId = "bbbb2222-3333-4444-5555-666677778888";
	auto dest = agent.createHistoryForkDestination(newSessionId,
		buildPath(sourceDir, "messages.jsonl"), profile);

	auto newDir = dirName(dest);
	assert(baseName(newDir).canFind("bbbb2222"),
		baseName(newDir));
	assert(baseName(newDir).startsWith("session_"), baseName(newDir));
	assert(baseName(dest) == "messages.jsonl");
	assert(!exists(dest), "forkTask writes the transcript, not the destination");

	auto meta = readText(buildPath(newDir, "meta.json"));
	assert(meta.canFind(`"session_id": "bbbb2222-3333-4444-5555-666677778888"`),
		meta);
	assert(meta.canFind(`"username": "alice"`), meta);
	assert(meta.canFind(`"origin_directory": "/work/proj"`), meta);
	assert(meta.canFind(`"total_messages": 2`), meta);
	// The pydantic-required fields must all be present as keys.
	foreach (field; ["start_time", "end_time", "git_commit", "git_branch",
		"environment", "child_sessions", "loops", "title_source"])
		assert(meta.canFind(field), field ~ " missing: " ~ meta);
}
