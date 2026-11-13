package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Store is the record in PostgreSQL (state model A, ADR 0028).
type Store struct {
	pool *pgxpool.Pool
}

// OpenStore connects with the libpq environment (PGHOST, PGDATABASE,
// PGUSER, PGPASSWORD, PGSSLMODE, PGSSLROOTCERT, ...), retrying until the
// database answers or ctx ends, and applies the migrations.
func OpenStore(ctx context.Context) (*Store, error) {
	cfg, err := pgxpool.ParseConfig("")
	if err != nil {
		return nil, err
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	for {
		err := pool.Ping(ctx)
		if err == nil {
			break
		}
		slog.WarnContext(ctx, "database not reachable, retrying", "error", err)
		select {
		case <-ctx.Done():
			pool.Close()
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	if err := migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, fmt.Errorf("migrations: %w", err)
	}
	return &Store{pool: pool}, nil
}

// migrate applies the embedded migrations under a PostgreSQL session lock,
// so that replicas starting together migrate once.
func migrate(ctx context.Context, pool *pgxpool.Pool) error {
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return err
	}
	dir, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, dir, goose.WithSessionLocker(locker))
	if err != nil {
		return err
	}
	results, err := provider.Up(ctx)
	for _, r := range results {
		slog.InfoContext(ctx, "migration applied", "version", r.Source.Version, "duration", r.Duration)
	}
	return err
}

func (s *Store) Close() { s.pool.Close() }

// Ping checks that the database answers.
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// Submit records a caller's message to an agent and returns its task, in
// state submitted. A message whose caller and messageId are already in the
// record is not recorded again: Submit returns its task and duplicate.
//
// A message without taskId starts a task, in the given context or a new
// one; the context must be the caller's, with the same agent. A message
// with taskId continues the caller's task if the task waits for input or
// authorization.
func (s *Store) Submit(ctx context.Context, agent string, msg *a2a.Message, p Provenance) (task *a2a.Task, duplicate bool, err error) {
	// A concurrent submission of the same message makes the insert fail on
	// the idempotency index; the second attempt finds the first's task.
	for attempt := 0; ; attempt++ {
		err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
			var id a2a.TaskID
			id, duplicate, err = submit(ctx, tx, agent, msg, p)
			if err != nil {
				return err
			}
			task, err = loadTask(ctx, tx, id, nil)
			return err
		})
		var pgErr *pgconn.PgError
		if attempt == 0 && errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "messages_idempotency" {
			continue
		}
		return task, duplicate, err
	}
}

func submit(ctx context.Context, tx pgx.Tx, agent string, msg *a2a.Message, p Provenance) (a2a.TaskID, bool, error) {
	var (
		taskID    a2a.TaskID
		taskAgent string
	)
	err := tx.QueryRow(ctx, `
		SELECT m.task_id, c.agent
		FROM messages m JOIN tasks t ON t.id = m.task_id JOIN contexts c ON c.id = t.context_id
		WHERE m.role = 'ROLE_USER' AND m.caller_issuer = $1 AND m.caller_subject = $2 AND m.message_id = $3`,
		p.Caller.Issuer, p.Caller.Subject, msg.ID).Scan(&taskID, &taskAgent)
	switch {
	case err == nil && taskAgent != agent:
		return "", false, fmt.Errorf("%w: messageId %q was sent to another agent", a2a.ErrInvalidParams, msg.ID)
	case err == nil:
		return taskID, true, nil
	case !errors.Is(err, pgx.ErrNoRows):
		return "", false, err
	}

	contextID := msg.ContextID
	if msg.TaskID != "" {
		taskID = msg.TaskID
		var state a2a.TaskState
		var owner taskOwner
		err := tx.QueryRow(ctx, `
			SELECT t.context_id, t.state, c.agent, c.caller_issuer, c.caller_subject
			FROM tasks t JOIN contexts c ON c.id = t.context_id
			WHERE t.id = $1 FOR UPDATE OF t`, taskID).
			Scan(&owner.contextID, &state, &owner.agent, &owner.caller.Issuer, &owner.caller.Subject)
		if errors.Is(err, pgx.ErrNoRows) || err == nil && !owner.is(agent, p.Caller) {
			return "", false, fmt.Errorf("%w: %s", a2a.ErrTaskNotFound, taskID)
		}
		if err != nil {
			return "", false, err
		}
		if contextID != "" && contextID != owner.contextID {
			return "", false, fmt.Errorf("%w: task %s belongs to context %s", a2a.ErrInvalidParams, taskID, owner.contextID)
		}
		if !acceptsMessage(state) {
			return "", false, fmt.Errorf("%w: task %s is %s and takes no further message", a2a.ErrUnsupportedOperation, taskID, state)
		}
		contextID = owner.contextID
		if err := setStatus(ctx, tx, taskID, a2a.TaskStatus{State: a2a.TaskStateSubmitted}); err != nil {
			return "", false, err
		}
	} else {
		if contextID == "" {
			contextID = a2a.NewContextID()
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO contexts (id, agent, caller_issuer, caller_subject) VALUES ($1, $2, $3, $4)
			ON CONFLICT (id) DO NOTHING`,
			contextID, agent, p.Caller.Issuer, p.Caller.Subject); err != nil {
			return "", false, err
		}
		var owner taskOwner
		if err := tx.QueryRow(ctx, `SELECT agent, caller_issuer, caller_subject FROM contexts WHERE id = $1`, contextID).
			Scan(&owner.agent, &owner.caller.Issuer, &owner.caller.Subject); err != nil {
			return "", false, err
		}
		if !owner.is(agent, p.Caller) {
			return "", false, fmt.Errorf("%w: context %s is not one of the caller's contexts with this agent", a2a.ErrInvalidParams, contextID)
		}
		taskID = a2a.NewTaskID()
		status, err := json.Marshal(a2a.TaskStatus{State: a2a.TaskStateSubmitted, Timestamp: now()})
		if err != nil {
			return "", false, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO tasks (id, context_id, state, status) VALUES ($1, $2, $3, $4)`,
			taskID, contextID, a2a.TaskStateSubmitted, status); err != nil {
			return "", false, err
		}
	}

	// The record keeps the message as the agent will see it: in its task
	// and context.
	recorded := *msg
	recorded.TaskID, recorded.ContextID = taskID, contextID
	body, err := json.Marshal(&recorded)
	if err != nil {
		return "", false, err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO messages (task_id, message_id, role, caller_issuer, caller_subject, principal, channel, body)
		VALUES ($1, $2, $3, $4, $5, $6, NULLIF($7, ''), $8)`,
		taskID, msg.ID, a2a.MessageRoleUser, p.Caller.Issuer, p.Caller.Subject, p.Principal, p.Channel, body)
	return taskID, false, err
}

// acceptsMessage tells whether a task in this state takes a further message
// from its caller: only while it waits for one.
func acceptsMessage(state a2a.TaskState) bool {
	return state == a2a.TaskStateInputRequired || state == a2a.TaskStateAuthRequired
}

type taskOwner struct {
	contextID string
	agent     string
	caller    Identity
}

func (o taskOwner) is(agent string, caller Identity) bool {
	return o.agent == agent && o.caller == caller
}

// Task returns the caller's task with this agent. Another caller's task, or
// one with another agent, is not found.
func (s *Store) Task(ctx context.Context, agent string, caller Identity, id a2a.TaskID, historyLength *int) (*a2a.Task, error) {
	var task *a2a.Task
	err := pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{AccessMode: pgx.ReadOnly, IsoLevel: pgx.RepeatableRead}, func(tx pgx.Tx) error {
		if _, err := owned(ctx, tx, agent, caller, id, false); err != nil {
			return err
		}
		var err error
		task, err = loadTask(ctx, tx, id, historyLength)
		return err
	})
	return task, err
}

// Cancel cancels the caller's task if it is not finished yet.
func (s *Store) Cancel(ctx context.Context, agent string, caller Identity, id a2a.TaskID) (*a2a.Task, error) {
	var task *a2a.Task
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		state, err := owned(ctx, tx, agent, caller, id, true)
		if err != nil {
			return err
		}
		if state.Terminal() {
			return fmt.Errorf("%w: task %s is %s", a2a.ErrTaskNotCancelable, id, state)
		}
		if err := setStatus(ctx, tx, id, a2a.TaskStatus{State: a2a.TaskStateCanceled}); err != nil {
			return err
		}
		task, err = loadTask(ctx, tx, id, nil)
		return err
	})
	return task, err
}

// owned returns the state of the task if it is the caller's with this agent.
func owned(ctx context.Context, tx pgx.Tx, agent string, caller Identity, id a2a.TaskID, lock bool) (a2a.TaskState, error) {
	query := `
		SELECT t.state FROM tasks t JOIN contexts c ON c.id = t.context_id
		WHERE t.id = $1 AND c.agent = $2 AND c.caller_issuer = $3 AND c.caller_subject = $4`
	if lock {
		query += ` FOR UPDATE OF t`
	}
	var state a2a.TaskState
	err := tx.QueryRow(ctx, query, id, agent, caller.Issuer, caller.Subject).Scan(&state)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("%w: %s", a2a.ErrTaskNotFound, id)
	}
	return state, err
}

func setStatus(ctx context.Context, tx pgx.Tx, id a2a.TaskID, status a2a.TaskStatus) error {
	status.Timestamp = now()
	body, err := json.Marshal(status)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE tasks SET state = $2, status = $3, updated_at = now() WHERE id = $1`, id, status.State, body)
	return err
}

// loadTask reads a task with its artifacts and the last historyLength
// messages (all if nil, none if 0).
func loadTask(ctx context.Context, tx pgx.Tx, id a2a.TaskID, historyLength *int) (*a2a.Task, error) {
	task := &a2a.Task{ID: id}
	var status, artifacts []byte
	if err := tx.QueryRow(ctx, `SELECT context_id, status, artifacts FROM tasks WHERE id = $1`, id).
		Scan(&task.ContextID, &status, &artifacts); err != nil {
		return nil, err
	}
	if err := json.Unmarshal(status, &task.Status); err != nil {
		return nil, fmt.Errorf("task %s: status: %w", id, err)
	}
	if err := json.Unmarshal(artifacts, &task.Artifacts); err != nil {
		return nil, fmt.Errorf("task %s: artifacts: %w", id, err)
	}
	limit := -1 // LIMIT ALL in the subquery below
	if historyLength != nil {
		limit = max(*historyLength, 0)
	}
	rows, err := tx.Query(ctx, `
		SELECT body FROM (
			SELECT seq, body FROM messages WHERE task_id = $1 ORDER BY seq DESC
			LIMIT CASE WHEN $2::int < 0 THEN NULL ELSE $2::int END
		) last ORDER BY seq`, id, limit)
	if err != nil {
		return nil, err
	}
	bodies, err := pgx.CollectRows(rows, pgx.RowTo[[]byte])
	if err != nil {
		return nil, err
	}
	for _, body := range bodies {
		var m a2a.Message
		if err := json.Unmarshal(body, &m); err != nil {
			return nil, fmt.Errorf("task %s: message: %w", id, err)
		}
		task.History = append(task.History, &m)
	}
	return task, nil
}

func now() *time.Time {
	t := time.Now().UTC()
	return &t
}
