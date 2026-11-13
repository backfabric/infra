package main

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/jackc/pgx/v5"
)

// newCaller is a caller no other test uses.
func newCaller() Provenance {
	id := Identity{Issuer: "kubernetes", Subject: "system:serviceaccount:test:" + a2a.NewMessageID()}
	return Provenance{Caller: id, Principal: id.Subject}
}

func userMessage(id, contextID string, taskID a2a.TaskID) *a2a.Message {
	return &a2a.Message{ID: id, ContextID: contextID, TaskID: taskID, Role: a2a.MessageRoleUser, Parts: a2a.ContentParts{a2a.NewTextPart("hello")}}
}

func TestSubmitIsIdempotent(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	alice, bob := newCaller(), newCaller()

	first, duplicate, err := s.Submit(ctx, "codex", userMessage("m1", "", ""), alice)
	if err != nil || duplicate {
		t.Fatalf("first submission: duplicate %v, error %v", duplicate, err)
	}
	if first.Status.State != a2a.TaskStateSubmitted || len(first.History) != 1 || first.History[0].ContextID != first.ContextID {
		t.Fatalf("first submission: %+v", first)
	}

	again, duplicate, err := s.Submit(ctx, "codex", userMessage("m1", "", ""), alice)
	if err != nil || !duplicate || again.ID != first.ID || len(again.History) != 1 {
		t.Errorf("resubmission: task %v, duplicate %v, error %v; want %s with one message", again, duplicate, err, first.ID)
	}

	// The same messageId of another caller is another message.
	other, duplicate, err := s.Submit(ctx, "codex", userMessage("m1", "", ""), bob)
	if err != nil || duplicate || other.ID == first.ID {
		t.Errorf("another caller's m1: task %v, duplicate %v, error %v", other, duplicate, err)
	}

	// The same caller's messageId for another agent is a conflict.
	if _, _, err := s.Submit(ctx, "claude", userMessage("m1", "", ""), alice); !errors.Is(err, a2a.ErrInvalidParams) {
		t.Errorf("m1 to another agent: %v, want invalid params", err)
	}
}

// Concurrent submissions of one new message: one wins, the others find its
// task.
func TestSubmitRacesForNewMessage(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	alice := newCaller()
	var wg sync.WaitGroup
	ids := make([]a2a.TaskID, 8)
	for i := range ids {
		wg.Go(func() {
			task, _, err := s.Submit(ctx, "codex", userMessage("race", "", ""), alice)
			if err != nil {
				t.Errorf("submission %d: %v", i, err)
				return
			}
			ids[i] = task.ID
		})
	}
	wg.Wait()
	for i := range ids {
		if ids[i] != ids[0] {
			t.Errorf("submission %d: task %s, want %s for all", i, ids[i], ids[0])
		}
	}
}

func TestContextsBelongToCallerAndAgent(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	alice, bob := newCaller(), newCaller()
	contextID := a2a.NewContextID()

	first, _, err := s.Submit(ctx, "codex", userMessage("c1", contextID, ""), alice)
	if err != nil || first.ContextID != contextID {
		t.Fatalf("caller-chosen context: %v, %v", first, err)
	}
	second, _, err := s.Submit(ctx, "codex", userMessage("c2", contextID, ""), alice)
	if err != nil || second.ContextID != contextID || second.ID == first.ID {
		t.Errorf("second message in the context: %v, %v; want a new task in %s", second, err, contextID)
	}
	if _, _, err := s.Submit(ctx, "codex", userMessage("c3", contextID, ""), bob); !errors.Is(err, a2a.ErrInvalidParams) {
		t.Errorf("another caller in the context: %v, want invalid params", err)
	}
	if _, _, err := s.Submit(ctx, "claude", userMessage("c4", contextID, ""), alice); !errors.Is(err, a2a.ErrInvalidParams) {
		t.Errorf("another agent in the context: %v, want invalid params", err)
	}
}

func TestTasksAreTheCallers(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	alice, bob := newCaller(), newCaller()
	task, _, err := s.Submit(ctx, "codex", userMessage("t1", "", ""), alice)
	if err != nil {
		t.Fatal(err)
	}

	got, err := s.Task(ctx, "codex", alice.Caller, task.ID, nil)
	if err != nil || got.ID != task.ID || len(got.History) != 1 || got.History[0].ID != "t1" {
		t.Errorf("own task: %v, %v", got, err)
	}
	none := 0
	if got, err := s.Task(ctx, "codex", alice.Caller, task.ID, &none); err != nil || len(got.History) != 0 {
		t.Errorf("historyLength 0: %v, %v; want no history", got, err)
	}
	for name, get := range map[string]func() error{
		"another caller": func() error { _, err := s.Task(ctx, "codex", bob.Caller, task.ID, nil); return err },
		"another agent":  func() error { _, err := s.Task(ctx, "claude", alice.Caller, task.ID, nil); return err },
		"cancel by another caller": func() error {
			_, err := s.Cancel(ctx, "codex", bob.Caller, task.ID)
			return err
		},
		"continue by another caller": func() error {
			_, _, err := s.Submit(ctx, "codex", userMessage("t2", "", task.ID), bob)
			return err
		},
	} {
		if err := get(); !errors.Is(err, a2a.ErrTaskNotFound) {
			t.Errorf("%s: %v, want task not found", name, err)
		}
	}
}

// setState moves a task as a turn would.
func setState(t *testing.T, s *Store, id a2a.TaskID, state a2a.TaskState) {
	t.Helper()
	err := pgx.BeginFunc(context.Background(), s.pool, func(tx pgx.Tx) error {
		return setStatus(context.Background(), tx, id, a2a.TaskStatus{State: state})
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestContinueTask(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	alice := newCaller()
	task, _, err := s.Submit(ctx, "codex", userMessage("k1", "", ""), alice)
	if err != nil {
		t.Fatal(err)
	}

	// While the task runs or is queued, it takes no further message.
	for _, state := range []a2a.TaskState{a2a.TaskStateSubmitted, a2a.TaskStateWorking} {
		setState(t, s, task.ID, state)
		if _, _, err := s.Submit(ctx, "codex", userMessage("k-"+string(state), "", task.ID), alice); !errors.Is(err, a2a.ErrUnsupportedOperation) {
			t.Errorf("message to a %s task: %v, want unsupported operation", state, err)
		}
	}

	setState(t, s, task.ID, a2a.TaskStateAuthRequired)
	if _, _, err := s.Submit(ctx, "codex", userMessage("k2", a2a.NewContextID(), task.ID), alice); !errors.Is(err, a2a.ErrInvalidParams) {
		t.Errorf("message to the task in another context: %v, want invalid params", err)
	}
	got, duplicate, err := s.Submit(ctx, "codex", userMessage("k3", "", task.ID), alice)
	if err != nil || duplicate {
		t.Fatalf("message to an auth-required task: %v, %v", got, err)
	}
	if got.ID != task.ID || got.Status.State != a2a.TaskStateSubmitted || len(got.History) != 2 || got.History[1].ID != "k3" {
		t.Errorf("continued task: %+v; want submitted again with both messages", got)
	}

	for _, state := range []a2a.TaskState{a2a.TaskStateCompleted, a2a.TaskStateFailed, a2a.TaskStateCanceled, a2a.TaskStateRejected} {
		setState(t, s, task.ID, state)
		if _, _, err := s.Submit(ctx, "codex", userMessage("k-"+string(state), "", task.ID), alice); !errors.Is(err, a2a.ErrUnsupportedOperation) {
			t.Errorf("message to a %s task: %v, want unsupported operation", state, err)
		}
	}
}

func TestCancel(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	alice := newCaller()
	for _, state := range []a2a.TaskState{a2a.TaskStateSubmitted, a2a.TaskStateInputRequired, a2a.TaskStateAuthRequired} {
		task, _, err := s.Submit(ctx, "codex", userMessage("x-"+string(state), "", ""), alice)
		if err != nil {
			t.Fatal(err)
		}
		setState(t, s, task.ID, state)
		got, err := s.Cancel(ctx, "codex", alice.Caller, task.ID)
		if err != nil || got.Status.State != a2a.TaskStateCanceled {
			t.Errorf("cancel a %s task: %v, %v", state, got, err)
		}
		if _, err := s.Cancel(ctx, "codex", alice.Caller, task.ID); !errors.Is(err, a2a.ErrTaskNotCancelable) {
			t.Errorf("cancel a canceled task: %v, want not cancelable", err)
		}
	}
}
