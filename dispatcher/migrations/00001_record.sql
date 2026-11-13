-- The record (ADR 0028, state model A): every A2A context, task, status,
-- artifact and message, with each message's provenance.

-- +goose Up

-- A context is one agent session, owned by the caller that started it.
CREATE TABLE contexts (
    id text PRIMARY KEY,
    agent text NOT NULL,
    caller_issuer text NOT NULL,
    caller_subject text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- A task is one turn of its context's agent. `state` is `status`'s state,
-- kept as a column for queries.
CREATE TABLE tasks (
    id text PRIMARY KEY,
    context_id text NOT NULL REFERENCES contexts (id),
    state text NOT NULL,
    -- The A2A TaskStatus (state, message, timestamp).
    status jsonb NOT NULL,
    -- The A2A Artifacts, in order.
    artifacts jsonb NOT NULL DEFAULT '[]',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX tasks_context ON tasks (context_id, created_at);

-- Messages of a task in order (seq), the caller's and the agent's. A
-- caller's message carries its provenance; an agent's has none.
CREATE TABLE messages (
    seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id text NOT NULL REFERENCES tasks (id),
    message_id text NOT NULL,
    role text NOT NULL,
    caller_issuer text,
    caller_subject text,
    principal text,
    channel text,
    -- The A2A Message as received or produced.
    body jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((role = 'ROLE_USER') = (caller_issuer IS NOT NULL AND caller_subject IS NOT NULL))
);

CREATE INDEX messages_task ON messages (task_id, seq);

-- Idempotent intake: one message per caller and messageId.
CREATE UNIQUE INDEX messages_idempotency ON messages (caller_issuer, caller_subject, message_id)
WHERE role = 'ROLE_USER';

-- +goose Down

DROP TABLE messages;
DROP TABLE tasks;
DROP TABLE contexts;
