// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/sql;
import ballerina/test;
import ballerinax/java.jdbc;

final readonly & ai:ChatFunctionMessage K1FN = {role: "function", name: "lookupOrder", content: "{\"id\":\"ORD-1\"}"};

function dropCheckpointTable() returns error? {
    jdbc:Client cl = getClient();
    _ = check cl->execute(`DROP TABLE IF EXISTS checkpoints`);
    _ = check cl->execute(`DROP TABLE IF EXISTS custom_checkpoints`);
}

// The checkpoint table schema. The store never creates this table; a deployment provisions it, so
// tests that exercise checkpoint operations must stand in for that deployment.
final sql:ParameterizedQuery createCheckpointTableQuery = `
    CREATE TABLE checkpoints (
        session_id TEXT PRIMARY KEY,
        approval_json TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`;

// `before` hook for tests that exercise checkpoint operations: clean slate, plus the
// deployment-provisioned checkpoint table those operations require.
function dropCheckpointTableAndProvision() returns error? {
    check dropCheckpointTable();
    jdbc:Client cl = getClient();
    _ = check cl->execute(createCheckpointTableQuery);
}

function buildPendingApproval(string sessionId) returns ai:PendingApproval {
    ai:FunctionCall toolCall = {name: "issueRefund", arguments: {orderId: "ORD-1", amount: 20}, id: "call-1"};
    ai:ApprovalRequest request = {
        id: "req-1",
        sessionId,
        toolName: "issueRefund",
        toolDescription: "Issues a refund for an order",
        arguments: {orderId: "ORD-1", amount: 20},
        toolCallId: "call-1",
        batchIndex: 0
    };
    ai:Iteration iteration = {
        history: [K1SM1, K1M1, k1m2],
        output: [k1m2, K1FN],
        startTime: [1700000000, 0.5d],
        endTime: [1700000001, 0.25d]
    };
    return {
        sessionId,
        executionId: "exec-1",
        iterationsUsed: 1,
        history: [K1SM1, K1M1, k1m2, K1FN],
        historyPrefixLength: 2,
        iterations: [iteration],
        toolCalls: [toolCall],
        startTime: [1700000000, 0d],
        originalBatch: [toolCall],
        pendingRequests: [request],
        decisions: [()]
    };
}

// `PendingApproval` is not statically `anydata` (its `history`/`iterations` admit `Prompt` and
// `Error`), so compare via the database-storable form, which captures every persisted field.
function assertCheckpointEquals(ai:PendingApproval? actual, ai:PendingApproval expected) {
    if actual !is ai:PendingApproval {
        test:assertFail("expected a persisted checkpoint but found none");
    }
    test:assertEquals(toApprovalDatabaseMessage(actual), toApprovalDatabaseMessage(expected));
}

function assertNoCheckpoint(ai:PendingApproval? actual) {
    test:assertEquals(actual, ());
}

@test:Config {
    before: dropCheckpointTable
}
function testCheckpointTableNotCreatedOnInit() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore _ = check new (cl);

    int tableExists = check cl->queryRow(
        `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'checkpoints'`);
    test:assertEquals(tableExists, 0,
            "The checkpoint table is the deployment's to provision, never the store's to create");
}

@test:Config {
    before: dropCheckpointTable
}
function testCustomCheckpointTableName() returns error? {
    jdbc:Client cl = getClient();
    _ = check cl->execute(`
        CREATE TABLE custom_checkpoints (
            session_id TEXT PRIMARY KEY,
            approval_json TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )`);

    ShortTermMemoryStore store = check new (cl, checkpointTableName = "custom_checkpoints");

    ai:PendingApproval approval = buildPendingApproval(K1);
    check store.putCheckpoint(approval);

    // The default-named table should not have been touched.
    int defaultTableExists = check cl->queryRow(
        `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'checkpoints'`);
    test:assertEquals(defaultTableExists, 0, "Default-named checkpoint table should not have been created");

    assertCheckpointEquals(check store.getCheckpoint(K1), approval);
}

@test:Config {}
function testInvalidCheckpointTableName() {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore|Error store = new (cl, checkpointTableName = "invalid-checkpoint-table-name");
    if store !is Error {
        test:assertFail("Expected an error for an invalid checkpoint table name");
    }
    test:assertTrue(store.message().includes("Invalid checkpoint table name"));
}

@test:Config {}
function testCheckpointTableNameCollidingWithMessagesTableRejected() {
    jdbc:Client cl = getClient();
    // Without this check, `initializeDatabase()` creates the messages schema under this name
    // eagerly at init, and the checkpoint operations then run against it - so every one of them
    // would fail with a confusing "no such column: session_id"-style SQL error instead of a
    // clear error here.
    ShortTermMemoryStore|Error store = new (cl, checkpointTableName = "chat_messages");
    if store !is Error {
        test:assertFail("Expected an error when checkpointTableName collides with tableName");
    }
    test:assertTrue(store.message().includes("must be different from the chat messages table name"));
}

@test:Config {
    before: dropCheckpointTable
}
function testRemoveAllDoesNotCreateCheckpointTable() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    // No checkpoint was ever put for this key, so the checkpoint table should not exist yet.
    check store.put(K1, K1SM1);
    check store.removeAll(K1);

    int tableExists = check cl->queryRow(
        `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'checkpoints'`);
    test:assertEquals(tableExists, 0,
            "removeAll should not create the checkpoint table when it does not already exist");
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testCheckpointPersistAndRetrieve() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    assertNoCheckpoint(check store.getCheckpoint(K1));

    ai:PendingApproval approval = buildPendingApproval(K1);
    check store.putCheckpoint(approval);

    // getCheckpoint returns an equal value and leaves it in place.
    assertCheckpointEquals(check store.getCheckpoint(K1), approval);
    assertCheckpointEquals(check store.getCheckpoint(K1), approval);

    // A checkpoint is scoped to its session.
    assertNoCheckpoint(check store.getCheckpoint(K2));
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testCheckpointReplace() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.putCheckpoint(buildPendingApproval(K1));

    ai:PendingApproval updated = buildPendingApproval(K1);
    updated.executionId = "exec-2";
    check store.putCheckpoint(updated);

    assertCheckpointEquals(check store.getCheckpoint(K1), updated);
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testTakeCheckpointClaimsAtomically() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    assertNoCheckpoint(check store.takeCheckpoint(K1));

    ai:PendingApproval approval = buildPendingApproval(K1);
    check store.putCheckpoint(approval);

    assertCheckpointEquals(check store.takeCheckpoint(K1), approval);

    // The checkpoint should no longer be present after being taken.
    assertNoCheckpoint(check store.takeCheckpoint(K1));
    assertNoCheckpoint(check store.getCheckpoint(K1));
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testRemoveCheckpoint() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.putCheckpoint(buildPendingApproval(K1));
    check store.removeCheckpoint(K1);
    assertNoCheckpoint(check store.getCheckpoint(K1));

    // Removing a checkpoint that doesn't exist should be a no-op, not an error.
    check store.removeCheckpoint(K2);
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testCheckpointClearedOnRemoveAll() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.putCheckpoint(buildPendingApproval(K1));

    check store.removeAll(K1);

    test:assertEquals(check store.getChatSystemMessage(K1), ());
    assertNoCheckpoint(check store.getCheckpoint(K1));
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testCheckpointErrorOutputStringified() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    ai:PendingApproval approval = buildPendingApproval(K1);
    approval.iterations[0].output = [k1m2, error ai:Error("tool execution failed", cause = error("timeout"))];
    check store.putCheckpoint(approval);

    ai:PendingApproval? retrieved = check store.getCheckpoint(K1);
    if retrieved !is ai:PendingApproval {
        test:assertFail("expected a persisted checkpoint");
    }
    var restoredError = retrieved.iterations[0].output[1];
    if restoredError !is error {
        test:assertFail("expected the second output entry to be an error");
    }
    test:assertTrue(restoredError.message().includes("tool execution failed"));
}

@test:Config {
    before: dropCheckpointTableAndProvision
}
function testCheckpointWithPromptContent() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    string city = "Seattle";
    ai:Prompt prompt = `What is the weather in ${city}?`;
    ai:ChatUserMessage userMessage = {role: ai:USER, content: prompt};

    ai:PendingApproval approval = buildPendingApproval(K1);
    approval.history = [userMessage];
    check store.putCheckpoint(approval);

    ai:PendingApproval? retrieved = check store.getCheckpoint(K1);
    if retrieved !is ai:PendingApproval {
        test:assertFail("expected a persisted checkpoint");
    }
    var restored = retrieved.history[0];
    if restored !is ai:ChatUserMessage {
        test:assertFail("expected a user message");
    }
    ai:Prompt|string content = restored.content;
    if content !is ai:Prompt {
        test:assertFail("expected the prompt content to round-trip as a Prompt");
    }
    test:assertEquals(content.strings, prompt.strings);
    test:assertEquals(content.insertions, prompt.insertions);
}

@test:Config {
    before: dropCheckpointTable
}
function testStoreNeverCreatesCheckpointTable() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    // Nothing the store does creates the checkpoint table: not initialization, not the message
    // operations, and not `removeAll`, which touches the checkpoint table when it exists.
    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    _ = check store.getAll(K1);
    check store.removeAll(K1);

    int tableExists = check cl->queryRow(
        `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'checkpoints'`);
    test:assertEquals(tableExists, 0, "The store must never create the checkpoint table");
}

@test:Config {
    before: dropCheckpointTable
}
function testCheckpointOperationsFailWithoutTable() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    // The checkpoint table is the deployment's to provision. If it is missing, every checkpoint
    // operation surfaces the database's own error naming the table, rather than silently creating
    // it or pretending nothing is pending.
    ai:PendingApproval?|Error read = store.getCheckpoint(K1);
    if read !is Error {
        test:assertFail("Expected an error when reading a checkpoint without a checkpoint table");
    }
    test:assertTrue(read.message().includes("checkpoints"), read.message());

    Error? written = store.putCheckpoint(buildPendingApproval(K1));
    if written !is Error {
        test:assertFail("Expected an error when persisting a checkpoint without a checkpoint table");
    }
    test:assertTrue(written.message().includes("checkpoints"), written.message());

    ai:PendingApproval?|Error claimed = store.takeCheckpoint(K1);
    if claimed !is Error {
        test:assertFail("Expected an error when claiming a checkpoint without a checkpoint table");
    }
    test:assertTrue(claimed.message().includes("checkpoints"), claimed.message());

    Error? removed = store.removeCheckpoint(K1);
    if removed !is Error {
        test:assertFail("Expected an error when removing a checkpoint without a checkpoint table");
    }
    test:assertTrue(removed.message().includes("checkpoints"), removed.message());

    int tableExists = check cl->queryRow(
        `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'checkpoints'`);
    test:assertEquals(tableExists, 0, "A failed checkpoint operation must not create the table");
}
