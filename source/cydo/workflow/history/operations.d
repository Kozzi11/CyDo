module cydo.workflow.history.operations;

import ae.utils.json : JSONOptional;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.runtime.config : AgentDriver;

enum HistoryOperation { fork, undo }
enum HistoryOperationMechanism { none, jsonl, codex_native }
enum CodexForkSourceState { dead, liveReady, liveBusy }

struct HistoryOperationKinds
{
	@JSONOptional HistoryOperationMechanism user;
	@JSONOptional HistoryOperationMechanism agent_turn;
}

struct HistoryOperations
{
	HistoryOperationKinds fork;
	HistoryOperationKinds undo;
}

HistoryOperations selectHistoryOperations(AgentDriver driver,
	CodexForkSourceState codexForkSource)
{
	HistoryOperations result;
	final switch (driver)
	{
	case AgentDriver.codex:
		break;
	case AgentDriver.claude:
	case AgentDriver.copilot:
		result.fork.user = HistoryOperationMechanism.jsonl;
		result.fork.agent_turn = HistoryOperationMechanism.jsonl;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		return result;
	case AgentDriver.vibe:
		// Fork and undo ride the generic jsonl machinery: the fork
		// destination is a synthesized session dir whose meta.json carries
		// the forked session_id (createHistoryForkDestination), and undo
		// truncates messages.jsonl in place — the session id is unchanged.
		result.fork.user = HistoryOperationMechanism.jsonl;
		result.fork.agent_turn = HistoryOperationMechanism.jsonl;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		return result;
	}
	switch (codexForkSource)
	{
	default:
		break;
	case CodexForkSourceState.dead:
		result.fork.user = HistoryOperationMechanism.codex_native;
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		break;
	case CodexForkSourceState.liveReady:
		result.fork.user = HistoryOperationMechanism.codex_native;
		result.fork.agent_turn = HistoryOperationMechanism.codex_native;
		result.undo.user = HistoryOperationMechanism.codex_native;
		break;
	case CodexForkSourceState.liveBusy:
		result.undo.user = HistoryOperationMechanism.jsonl;
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
		break;
	}
	return result;
}

bool allowsOperation(const HistoryBoundary boundary, const HistoryOperations operations,
	HistoryOperation operation)
{
	auto kinds = operation == HistoryOperation.fork ? operations.fork : operations.undo;
	return boundary.anchor.length > 0 && (boundary.kind == HistoryBoundaryKind.user
		? kinds.user != HistoryOperationMechanism.none
		: kinds.agent_turn != HistoryOperationMechanism.none);
}

bool allowsFileRevert(const HistoryBoundary boundary)
{
	return boundary.checkpoint_uuid.length > 0;
}

unittest
{
	import cydo.protocol : HistoryBoundary;
	auto offline = selectHistoryOperations(AgentDriver.codex,
		CodexForkSourceState.dead);
	assert(offline.fork.user == HistoryOperationMechanism.codex_native);
	assert(offline.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(offline.undo.user == HistoryOperationMechanism.jsonl);
	assert(offline.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto native = selectHistoryOperations(AgentDriver.codex,
		CodexForkSourceState.liveReady);
	assert(native.fork.user == HistoryOperationMechanism.codex_native);
	assert(native.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(native.undo.user == HistoryOperationMechanism.codex_native);
	assert(native.undo.agent_turn == HistoryOperationMechanism.none);
	auto busy = selectHistoryOperations(AgentDriver.codex,
		CodexForkSourceState.liveBusy);
	assert(busy.fork.user == HistoryOperationMechanism.none);
	assert(busy.fork.agent_turn == HistoryOperationMechanism.none);
	assert(busy.undo.user == HistoryOperationMechanism.jsonl);
	assert(busy.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto claude = selectHistoryOperations(AgentDriver.claude,
		CodexForkSourceState.dead);
	assert(claude.fork.user == HistoryOperationMechanism.jsonl);
	assert(claude.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto vibe = selectHistoryOperations(AgentDriver.vibe,
		CodexForkSourceState.dead);
	assert(vibe.fork.user == HistoryOperationMechanism.jsonl);
	assert(vibe.fork.agent_turn == HistoryOperationMechanism.jsonl);
	assert(vibe.undo.user == HistoryOperationMechanism.jsonl);
	assert(vibe.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto boundary = HistoryBoundary("a", HistoryBoundaryKind.agent_turn, "");
	assert(allowsOperation(boundary, offline, HistoryOperation.undo));
	assert(!allowsOperation(boundary, native, HistoryOperation.undo));
	assert(!allowsFileRevert(boundary));
	boundary.checkpoint_uuid = "checkpoint";
	assert(allowsFileRevert(boundary));
}
