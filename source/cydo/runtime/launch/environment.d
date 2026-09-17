module cydo.runtime.launch.environment;

import std.exception : enforce;
import std.path : buildPath, isAbsolute;
import std.process : environment;

import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ResolvedSandbox;

struct ChildEnvValue
{
	bool present;
	string value;
}

string isolatedChildHomeBaseline()
{
	return environment.get("HOME", "/tmp");
}

ChildEnvValue effectiveChildEnvValue(
	const ref ResolvedSandbox sandbox, string name)
{
	if (auto value = name in sandbox.env)
		return ChildEnvValue(true, *value);

	if (!sandbox.isolate_environment)
	{
		auto backendEnv = environment.toAA();
		if (auto value = name in backendEnv)
			return ChildEnvValue(true, *value);
		return ChildEnvValue(false, "");
	}

	if (name == "HOME")
		return ChildEnvValue(true, isolatedChildHomeBaseline());
	return ChildEnvValue(false, "");
}

NativeHistoryProfile resolveNativeHistoryProfile(
	const ref ResolvedSandbox sandbox,
	const ref NativeHistoryRule rule)
{
	auto home = effectiveChildEnvValue(sandbox, "HOME");
	enforce(home.present && home.value.length > 0,
		"Native history configuration requires a nonempty effective HOME");
	enforce(isAbsolute(home.value),
		"Native history configuration requires an absolute effective HOME: "
		~ home.value);

	auto configuredRoot = effectiveChildEnvValue(sandbox, rule.profileEnvName);
	string root;
	if (configuredRoot.present)
	{
		enforce(configuredRoot.value.length > 0,
			"Native history configuration " ~ rule.profileEnvName
			~ " must not be empty");
		enforce(isAbsolute(configuredRoot.value),
			"Native history configuration " ~ rule.profileEnvName
			~ " must be an absolute path: " ~ configuredRoot.value);
		root = configuredRoot.value;
	}
	else
		root = buildPath(home.value, rule.homeRelativeDefault);

	enforce(root.length > 0,
		"Native history configuration resolved an empty profile root");
	enforce(isAbsolute(root),
		"Native history configuration resolved a non-absolute profile root: " ~ root);
	return NativeHistoryProfile(rule.driver, root);
}

unittest
{
	import std.algorithm : canFind;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.config : AgentDriver;

	auto root = buildPath("/tmp", "cydo-native-history-effective-env");
	auto hostHome = buildPath(root, "host-home");
	auto hostProfile = buildPath(root, "host-profile");
	auto explicitHome = buildPath(root, "explicit-home");
	auto explicitProfile = buildPath(root, "explicit-profile");
	auto oldHome = environment.get("HOME", "");
	auto oldProfile = environment.get("CODEX_HOME", "");
	bool hadHome = "HOME" in environment;
	bool hadProfile = "CODEX_HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
		if (hadProfile)
			environment["CODEX_HOME"] = oldProfile;
		else
			environment.remove("CODEX_HOME");
	}
	environment["HOME"] = hostHome;
	environment["CODEX_HOME"] = hostProfile;

	auto rule = NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	void expectConfigurationFailure(void delegate() action, string expectedText)
	{
		bool thrown;
		try
			action();
		catch (Exception e)
		{
			thrown = true;
			assert(e.msg.canFind(expectedText), e.msg);
		}
		assert(thrown);
	}

	ResolvedSandbox explicitSandbox;
	explicitSandbox.env["HOME"] = explicitHome;
	explicitSandbox.env["CODEX_HOME"] = explicitProfile;
	auto explicitHomeValue = effectiveChildEnvValue(explicitSandbox, "HOME");
	auto explicitProfileValue = effectiveChildEnvValue(explicitSandbox, "CODEX_HOME");
	assert(explicitHomeValue.present && explicitHomeValue.value == explicitHome);
	assert(explicitProfileValue.present && explicitProfileValue.value == explicitProfile);
	auto explicitResolved = resolveNativeHistoryProfile(explicitSandbox, rule);
	assert(explicitResolved.driver == AgentDriver.codex);
	assert(explicitResolved.root == explicitProfile);

	ResolvedSandbox inheritedSandbox;
	auto inheritedHome = effectiveChildEnvValue(inheritedSandbox, "HOME");
	auto inheritedProfile = effectiveChildEnvValue(inheritedSandbox, "CODEX_HOME");
	assert(inheritedHome.present && inheritedHome.value == hostHome);
	assert(inheritedProfile.present && inheritedProfile.value == hostProfile);
	assert(resolveNativeHistoryProfile(inheritedSandbox, rule).root == hostProfile);

	// Backend presence is preserved even when the inherited value is empty.
	environment["CODEX_HOME"] = "";
	auto inheritedEmptyProfile = effectiveChildEnvValue(inheritedSandbox, "CODEX_HOME");
	assert(inheritedEmptyProfile.present && inheritedEmptyProfile.value.length == 0);
	expectConfigurationFailure({ resolveNativeHistoryProfile(inheritedSandbox, rule); },
		"CODEX_HOME");
	environment["CODEX_HOME"] = hostProfile;

	ResolvedSandbox isolatedSandbox;
	isolatedSandbox.isolate_environment = true;
	auto isolatedHome = effectiveChildEnvValue(isolatedSandbox, "HOME");
	auto isolatedProfile = effectiveChildEnvValue(isolatedSandbox, "CODEX_HOME");
	assert(isolatedHome.present && isolatedHome.value == isolatedChildHomeBaseline());
	assert(isolatedHome.value == hostHome);
	assert(!isolatedProfile.present);
	assert(resolveNativeHistoryProfile(isolatedSandbox, rule).root
		== buildPath(hostHome, ".codex"));

	// All rules use their concrete default only after child HOME selection.
	NativeHistoryRule[] rules = [
		NativeHistoryRule(AgentDriver.claude, "CLAUDE_CONFIG_DIR", ".claude", null),
		NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null),
		NativeHistoryRule(AgentDriver.copilot, "COPILOT_HOME", ".copilot", null),
		NativeHistoryRule(AgentDriver.vibe, "VIBE_HOME", ".vibe", null),
	];
	foreach (testRule; rules)
	{
		ResolvedSandbox defaultSandbox;
		defaultSandbox.isolate_environment = true;
		defaultSandbox.env["HOME"] = explicitHome;
		assert(resolveNativeHistoryProfile(defaultSandbox, testRule).root
			== buildPath(explicitHome, testRule.homeRelativeDefault));

		auto selectedRoot = buildPath(root, "explicit-" ~ testRule.profileEnvName);
		defaultSandbox.env[testRule.profileEnvName] = selectedRoot;
		assert(resolveNativeHistoryProfile(defaultSandbox, testRule).root == selectedRoot);
	}

	explicitSandbox.env["CODEX_HOME"] = "";
	expectConfigurationFailure({ resolveNativeHistoryProfile(explicitSandbox, rule); },
		"CODEX_HOME");
	explicitSandbox.env["CODEX_HOME"] = "relative-profile";
	expectConfigurationFailure({ resolveNativeHistoryProfile(explicitSandbox, rule); },
		"CODEX_HOME");
	explicitSandbox.env["CODEX_HOME"] = explicitProfile;
	explicitSandbox.env["HOME"] = "";
	expectConfigurationFailure({ resolveNativeHistoryProfile(explicitSandbox, rule); }, "HOME");
	explicitSandbox.env["HOME"] = "relative-home";
	expectConfigurationFailure({ resolveNativeHistoryProfile(explicitSandbox, rule); }, "HOME");

	// The absent isolated HOME path uses the shared renderer fallback when the
	// backend also has no HOME value.
	environment.remove("HOME");
	ResolvedSandbox fallbackHomeSandbox;
	fallbackHomeSandbox.isolate_environment = true;
	assert(effectiveChildEnvValue(fallbackHomeSandbox, "HOME").value == "/tmp");
	assert(resolveNativeHistoryProfile(fallbackHomeSandbox, rule).root
		== "/tmp/.codex");
}

unittest
{
	import cydo.runtime.config : AgentDriver;

	// Sandbox resolution renders templates and tildes before this boundary.
	// The native-history resolver must use that resulting child value verbatim.
	ResolvedSandbox sandbox;
	sandbox.env["HOME"] = "/tmp/cydo-rendered-home";
	sandbox.env["CODEX_HOME"] = "/tmp/cydo/{{ env.NOT_RENDERED_TWICE }}/~/profile";
	auto rule = NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	assert(profile.root == "/tmp/cydo/{{ env.NOT_RENDERED_TWICE }}/~/profile");
}
