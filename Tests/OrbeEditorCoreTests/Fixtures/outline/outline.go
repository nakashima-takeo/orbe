package server

import (
	"context"
	"net/http"
)

const DefaultPort = 8080

const (
	StateIdle State = iota
	StateRunning
)

var (
	ErrClosed = errors.New("closed")
	registry  map[string]*Server
)

var debug, verbose bool

type State int

type Handler func(ctx context.Context) error

type Server struct {
	Addr    string
	handler Handler
	opts    struct {
		Timeout int
		Retries int
	}
	*http.Server `json:"-"`
	A, B int
}

type Store[K comparable, V any] interface {
	Get(key K) (V, bool)
	Put(key K, value V)
	io.Closer
}

func New(addr string) *Server {
	type local struct{ a int }
	tests := []struct {
		name string
		want int
	}{}
	_ = tests
	s := &Server{Addr: addr}
	helper := func() { type inner struct{ b int } }
	helper()
	return s
}

func (s *Server) Start(ctx context.Context) error {
	var attempts int
	for attempts = 0; attempts < 3; attempts++ {
	}
	return nil
}

func (Server) Name() string { return "server" }

func (l *List[T]) Push(v T) {}

func init() {
	registry = map[string]*Server{}
}
