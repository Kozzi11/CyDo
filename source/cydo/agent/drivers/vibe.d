module cydo.agent.drivers.vibe;

import cydo.agent.contract : Agent, DiscoveredSession, InterruptedToolCallRepair,
	OneShotHandle, PersistedHistoryBoundary, RewindResult, SessionConfig,
	SessionMeta;
import cydo.agent.session : AgentSession;
import cydo.protocol : TranslatedEvent;
import cydo.runtime.config : AgentDriver, ModelSpec;
import cydo.runtime.launch.sandbox_paths : SandboxPaths;
import cydo.runtime.launch.sandbox : effectiveEnvValue;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;

// ---------------------------------------------------------------------------
// VibeAgent — Agent descriptor for Mistral Vibe (`vibe-acp`, ACP wire
// protocol). Registration-level skeleton: identity, sandbox hooks, and model
// resolution are in place; the ACP session transport is not implemented yet,
// so createSession/completeOneShot throw and history translation yields
// nothing.
// ---------------------------------------------------------------------------

class VibeAgent : Agent
{
	private ModelSpec[string] modelAliasOverrides;

	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
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
		throw new Exception("The Mistral Vibe session transport is not implemented yet");
	}

	string extractResultText(string line) { return null; }

	string extractAssistantText(string line) { return null; }

	string extractUserText(string line) { return null; }

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "devstral-2-small";
			case "medium": return "devstral-2";
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
		return [];
	}

	bool isTurnResult(string rawLine) { return false; }

	bool isUserMessageLine(string rawLine) { return false; }

	bool isAssistantMessageLine(string rawLine) { return false; }

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
		throw new Exception("Mistral Vibe one-shot completion is not implemented yet");
	}
}
