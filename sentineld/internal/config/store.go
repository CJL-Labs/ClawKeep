package config

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/BurntSushi/toml"
)

type Store struct {
	path string
	mu   sync.RWMutex
	cfg  *Config
}

func NewStore(path string, cfg *Config) *Store {
	return &Store{path: path, cfg: cfg}
}

func (s *Store) Config() *Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	copyCfg := *s.cfg
	return &copyCfg
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
	defer s.mu.Unlock()
	s.cfg = cfg
	return nil
}
