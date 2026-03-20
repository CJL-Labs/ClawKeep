package config

import (
	"context"
	"os"
	"path/filepath"
	"sync"

	"github.com/BurntSushi/toml"
	"github.com/fsnotify/fsnotify"
)

type Store struct {
	path string
	mu   sync.RWMutex
	cfg  *Config

	subscribers map[int]chan *Config
	nextID      int
}

func NewStore(path string, cfg *Config) *Store {
	return &Store{
		path:        path,
		cfg:         Clone(cfg),
		subscribers: make(map[int]chan *Config),
	}
}

func (s *Store) Config() *Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return Clone(s.cfg)
}

func (s *Store) Replace(cfg *Config) error {
	if err := cfg.normalize(); err != nil {
		return err
	}
	if err := cfg.Validate(); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	file, err := os.Create(s.path)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := toml.NewEncoder(file).Encode(cfg); err != nil {
		return err
	}

	s.mu.Lock()
	s.cfg = Clone(cfg)
	subscribers := s.snapshotSubscribersLocked()
	current := Clone(s.cfg)
	s.mu.Unlock()

	s.publish(subscribers, current)
	return nil
}

func (s *Store) Subscribe() (<-chan *Config, func()) {
	s.mu.Lock()
	defer s.mu.Unlock()

	channel := make(chan *Config, 4)
	id := s.nextID
	s.nextID++
	s.subscribers[id] = channel
	channel <- Clone(s.cfg)

	cancel := func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		subscriber, ok := s.subscribers[id]
		if !ok {
			return
		}
		delete(s.subscribers, id)
		close(subscriber)
	}
	return channel, cancel
}

func (s *Store) Run(ctx context.Context) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer watcher.Close()

	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := watcher.Add(dir); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-watcher.Events:
			if !ok {
				return nil
			}
			if filepath.Clean(event.Name) != filepath.Clean(s.path) {
				continue
			}
			if event.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Rename) == 0 {
				continue
			}
			cfg, loadErr := Load(s.path)
			if loadErr != nil {
				continue
			}
			s.mu.Lock()
			s.cfg = cfg
			subscribers := s.snapshotSubscribersLocked()
			current := Clone(s.cfg)
			s.mu.Unlock()
			s.publish(subscribers, current)
		case _, ok := <-watcher.Errors:
			if !ok {
				return nil
			}
		}
	}
}

func (s *Store) snapshotSubscribersLocked() []chan *Config {
	subscribers := make([]chan *Config, 0, len(s.subscribers))
	for _, subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	return subscribers
}

func (s *Store) publish(subscribers []chan *Config, cfg *Config) {
	for _, subscriber := range subscribers {
		select {
		case subscriber <- Clone(cfg):
		default:
		}
	}
}
