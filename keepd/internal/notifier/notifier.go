package notifier

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/smtp"
	"net/url"
	"strings"
	"sync"
	"time"

	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/logging"
)

type Event string

const (
	EventCrash         Event = "crash"
	EventRepairStart   Event = "repair_start"
	EventRepairSuccess Event = "repair_success"
	EventRepairFail    Event = "repair_fail"
	EventAgentTimeout  Event = "agent_timeout"
)

type Message struct {
	Title string
	Body  string
}

type Sender interface {
	Send(ctx context.Context, event Event, message Message) error
}

type Manager struct {
	mu            sync.RWMutex
	config        config.NotifyConfig
	enabledEvents map[Event]struct{}
	senders       map[string]Sender
	logger        *logging.Logger
}

func NewManager(cfg config.NotifyConfig, logger *logging.Logger) *Manager {
	manager := &Manager{logger: logger}
	manager.ApplyConfig(cfg)
	return manager
}

func (m *Manager) Notify(ctx context.Context, event Event, message Message) error {
	m.mu.RLock()
	if _, ok := m.enabledEvents[event]; !ok {
		m.mu.RUnlock()
		return nil
	}
	senders := make([]Sender, 0, len(m.senders))
	for _, sender := range m.senders {
		senders = append(senders, sender)
	}
	m.mu.RUnlock()
	for _, sender := range senders {
		if err := sender.Send(ctx, event, message); err != nil {
			m.logger.Warn("notification failed", "event", string(event), "error", err.Error())
		}
	}
	return nil
}

func (m *Manager) ApplyConfig(cfg config.NotifyConfig) {
	events := make(map[Event]struct{}, len(cfg.NotifyOn))
	for _, event := range cfg.NotifyOn {
		events[Event(event)] = struct{}{}
	}
	senders := make(map[string]Sender)
	if cfg.Feishu.Enabled && cfg.Feishu.WebhookURL != "" {
		senders["feishu"] = &feishuSender{cfg: cfg.Feishu}
	}
	if cfg.Bark.Enabled && cfg.Bark.PushURL != "" {
		senders["bark"] = &barkSender{cfg: cfg.Bark}
	}
	if cfg.SMTP.Enabled && cfg.SMTP.Host != "" && len(cfg.SMTP.To) > 0 {
		senders["smtp"] = &smtpSender{cfg: cfg.SMTP}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.config = cfg
	m.enabledEvents = events
	m.senders = senders
}

func (m *Manager) TestChannel(ctx context.Context, channel string, message Message) error {
	m.mu.RLock()
	sender, ok := m.senders[strings.ToLower(channel)]
	m.mu.RUnlock()
	if !ok {
		return fmt.Errorf("notification channel %q is not configured", channel)
	}
	return sender.Send(ctx, EventCrash, message)
}

type feishuSender struct {
	cfg config.FeishuConfig
}

func (s *feishuSender) Send(ctx context.Context, event Event, message Message) error {
	payload := map[string]any{
		"msg_type": "text",
		"content": map[string]string{
			"text": message.Title + "\n" + message.Body,
		},
	}
	if s.cfg.Secret != "" {
		timestamp := fmt.Sprintf("%d", time.Now().Unix())
		signature := signFeishu(timestamp, s.cfg.Secret)
		payload["timestamp"] = timestamp
		payload["sign"] = signature
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.WebhookURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode >= 300 {
		return fmt.Errorf("feishu webhook returned status %d", response.StatusCode)
	}
	var result struct {
		Code int    `json:"code"`
		Msg  string `json:"msg"`
	}
	if len(responseBody) > 0 && json.Unmarshal(responseBody, &result) == nil && result.Code != 0 {
		return fmt.Errorf("feishu webhook rejected request: %s (code %d)", result.Msg, result.Code)
	}
	return nil
}

type barkSender struct {
	cfg config.BarkConfig
}

func (s *barkSender) Send(ctx context.Context, event Event, message Message) error {
	escapedTitle := url.PathEscape(message.Title)
	escapedBody := url.PathEscape(message.Body)
	endpoint := strings.TrimRight(s.cfg.PushURL, "/") + "/" + escapedTitle + "/" + escapedBody
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode >= 300 {
		return fmt.Errorf("bark returned status %d", response.StatusCode)
	}
	var result struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	if len(responseBody) > 0 && json.Unmarshal(responseBody, &result) == nil && result.Code != 200 {
		return fmt.Errorf("bark rejected request: %s (code %d)", result.Message, result.Code)
	}
	return nil
}

type smtpSender struct {
	cfg config.SMTPConfig
}

func (s *smtpSender) Send(_ context.Context, event Event, message Message) error {
	address := fmt.Sprintf("%s:%d", s.cfg.Host, s.cfg.Port)
	auth := smtp.PlainAuth("", s.cfg.Username, s.cfg.Password, s.cfg.Host)
	plainText := message.Body
	htmlBody := "<html><body><h3>" + escapeHTML(message.Title) + "</h3><pre style=\"font-family: Menlo, monospace; white-space: pre-wrap;\">" + escapeHTML(message.Body) + "</pre></body></html>"
	headers := []string{
		"From: " + s.cfg.From,
		"To: " + strings.Join(s.cfg.To, ","),
		"Subject: " + message.Title,
		"MIME-Version: 1.0",
		"Content-Type: multipart/alternative; boundary=clawkeep-boundary",
		"",
		"--clawkeep-boundary",
		"Content-Type: text/plain; charset=UTF-8",
		"",
		plainText,
		"",
		"--clawkeep-boundary",
		"Content-Type: text/html; charset=UTF-8",
		"",
		htmlBody,
		"",
		"--clawkeep-boundary--",
	}
	payload := []byte(strings.Join(headers, "\r\n"))
	if !s.cfg.UseTLS {
		return smtp.SendMail(address, auth, s.cfg.From, s.cfg.To, payload)
	}

	connection, err := tls.Dial("tcp", address, &tls.Config{ServerName: s.cfg.Host, MinVersion: tls.VersionTLS12})
	if err != nil {
		return err
	}
	defer connection.Close()

	client, err := smtp.NewClient(connection, s.cfg.Host)
	if err != nil {
		return err
	}
	defer client.Quit()
	if err := client.Auth(auth); err != nil {
		return err
	}
	if err := client.Mail(s.cfg.From); err != nil {
		return err
	}
	for _, recipient := range s.cfg.To {
		if err := client.Rcpt(recipient); err != nil {
			return err
		}
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := writer.Write(payload); err != nil {
		_ = writer.Close()
		return err
	}
	return writer.Close()
}

func signFeishu(timestamp string, secret string) string {
	payload := timestamp + "\n" + secret
	sum := hmac.New(sha256.New, []byte(payload))
	_, _ = sum.Write([]byte{})
	signature := sum.Sum(nil)
	return base64.StdEncoding.EncodeToString(signature)
}

func escapeHTML(value string) string {
	replacer := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		"\"", "&quot;",
		"'", "&#39;",
	)
	return replacer.Replace(value)
}
