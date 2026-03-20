package notifier

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/smtp"
	"net/url"
	"strings"
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
	EventRestart       Event = "restart"
)

type Message struct {
	Title string
	Body  string
}

type Sender interface {
	Send(ctx context.Context, event Event, message Message) error
}

type Manager struct {
	enabledEvents map[Event]struct{}
	senders       []Sender
	logger        *logging.Logger
}

func NewManager(cfg config.NotifyConfig, logger *logging.Logger) *Manager {
	events := make(map[Event]struct{}, len(cfg.NotifyOn))
	for _, event := range cfg.NotifyOn {
		events[Event(event)] = struct{}{}
	}
	var senders []Sender
	if cfg.Feishu.Enabled && cfg.Feishu.WebhookURL != "" {
		senders = append(senders, &feishuSender{cfg: cfg.Feishu})
	}
	if cfg.Bark.Enabled && cfg.Bark.DeviceKey != "" {
		senders = append(senders, &barkSender{cfg: cfg.Bark})
	}
	if cfg.SMTP.Enabled && cfg.SMTP.Host != "" && len(cfg.SMTP.To) > 0 {
		senders = append(senders, &smtpSender{cfg: cfg.SMTP})
	}
	return &Manager{
		enabledEvents: events,
		senders:       senders,
		logger:        logger,
	}
}

func (m *Manager) Notify(ctx context.Context, event Event, message Message) error {
	if _, ok := m.enabledEvents[event]; !ok {
		return nil
	}
	for _, sender := range m.senders {
		if err := sender.Send(ctx, event, message); err != nil {
			m.logger.Warn("notification failed", "event", string(event), "error", err.Error())
		}
	}
	return nil
}

type feishuSender struct {
	cfg config.FeishuConfig
}

func (s *feishuSender) Send(ctx context.Context, event Event, message Message) error {
	payload := map[string]any{
		"msg_type": "interactive",
		"card": map[string]any{
			"header": map[string]any{
				"title": map[string]string{
					"tag":     "plain_text",
					"content": message.Title,
				},
			},
			"elements": []map[string]any{
				{
					"tag": "div",
					"text": map[string]string{
						"tag":     "lark_md",
						"content": message.Body,
					},
				},
			},
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
	if response.StatusCode >= 300 {
		return fmt.Errorf("feishu webhook returned status %d", response.StatusCode)
	}
	return nil
}

type barkSender struct {
	cfg config.BarkConfig
}

func (s *barkSender) Send(ctx context.Context, event Event, message Message) error {
	escapedTitle := url.PathEscape(message.Title)
	escapedBody := url.PathEscape(message.Body)
	endpoint := strings.TrimRight(s.cfg.ServerURL, "/") + "/" + s.cfg.DeviceKey + "/" + escapedTitle + "/" + escapedBody
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode >= 300 {
		return fmt.Errorf("bark returned status %d", response.StatusCode)
	}
	return nil
}

type smtpSender struct {
	cfg config.SMTPConfig
}

func (s *smtpSender) Send(_ context.Context, event Event, message Message) error {
	address := fmt.Sprintf("%s:%d", s.cfg.Host, s.cfg.Port)
	auth := smtp.PlainAuth("", s.cfg.Username, s.cfg.Password, s.cfg.Host)
	headers := []string{
		"From: " + s.cfg.From,
		"To: " + strings.Join(s.cfg.To, ","),
		"Subject: " + message.Title,
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=UTF-8",
		"",
		message.Body,
	}
	return smtp.SendMail(address, auth, s.cfg.From, s.cfg.To, []byte(strings.Join(headers, "\r\n")))
}

func signFeishu(timestamp string, secret string) string {
	payload := timestamp + "\n" + secret
	sum := hmac.New(sha256.New, []byte(secret))
	_, _ = sum.Write([]byte(payload))
	signature := sum.Sum(nil)
	return base64.StdEncoding.EncodeToString(signature)
}
