package notifier

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"claw-keep/keepd/internal/config"
)

func TestFeishuSenderSendsTextPayload(t *testing.T) {
	t.Parallel()

	var payload map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost {
			t.Fatalf("unexpected method: %s", request.Method)
		}
		if got := request.Header.Get("Content-Type"); got != "application/json" {
			t.Fatalf("unexpected content type: %s", got)
		}
		defer request.Body.Close()
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":0,"msg":"success"}`))
	}))
	defer server.Close()

	sender := feishuSender{cfg: config.FeishuConfig{WebhookURL: server.URL}}
	message := Message{Title: "ClawKeep test", Body: "OpenClaw status is healthy"}
	if err := sender.Send(context.Background(), EventCrash, message); err != nil {
		t.Fatalf("send feishu message: %v", err)
	}

	if got := payload["msg_type"]; got != "text" {
		t.Fatalf("unexpected msg_type: %v", got)
	}
	content, ok := payload["content"].(map[string]any)
	if !ok {
		t.Fatalf("missing content payload: %#v", payload["content"])
	}
	if got := content["text"]; got != "ClawKeep test\nOpenClaw status is healthy" {
		t.Fatalf("unexpected text body: %v", got)
	}
}

func TestFeishuSenderSignsRequestWhenSecretConfigured(t *testing.T) {
	t.Parallel()

	var payload map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		defer request.Body.Close()
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":0,"msg":"success"}`))
	}))
	defer server.Close()

	sender := feishuSender{cfg: config.FeishuConfig{WebhookURL: server.URL, Secret: "demo-secret"}}
	if err := sender.Send(context.Background(), EventCrash, Message{Title: "title", Body: "body"}); err != nil {
		t.Fatalf("send feishu message: %v", err)
	}

	timestamp, ok := payload["timestamp"].(string)
	if !ok || timestamp == "" {
		t.Fatalf("missing timestamp: %#v", payload)
	}
	sign, ok := payload["sign"].(string)
	if !ok || sign == "" {
		t.Fatalf("missing sign: %#v", payload)
	}
	if expected := signFeishu(timestamp, "demo-secret"); sign != expected {
		t.Fatalf("unexpected sign: got %q want %q", sign, expected)
	}
}

func TestBarkSenderAppendsTitleAndBodyToPushURL(t *testing.T) {
	t.Parallel()

	var escapedPath string
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		escapedPath = request.URL.EscapedPath()
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":200,"message":"success"}`))
	}))
	defer server.Close()

	sender := barkSender{cfg: config.BarkConfig{PushURL: server.URL + "/token-value"}}
	message := Message{Title: "ClawKeep test", Body: "Gateway recovered"}
	if err := sender.Send(context.Background(), EventCrash, message); err != nil {
		t.Fatalf("send bark message: %v", err)
	}

	if expected := "/token-value/ClawKeep%20test/Gateway%20recovered"; escapedPath != expected {
		t.Fatalf("unexpected bark path: got %q want %q", escapedPath, expected)
	}
}

func TestBarkSenderReturnsErrorOnRejectedResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":400,"message":"bad request"}`))
	}))
	defer server.Close()

	sender := barkSender{cfg: config.BarkConfig{PushURL: server.URL + "/token-value"}}
	if err := sender.Send(context.Background(), EventCrash, Message{Title: "title", Body: "body"}); err == nil {
		t.Fatal("expected bark sender to fail")
	}
}

func TestManagerTestChannelAllowsDisabledFeishuConfig(t *testing.T) {
	t.Parallel()

	received := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		defer request.Body.Close()

		var payload map[string]any
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		content, ok := payload["content"].(map[string]any)
		if !ok {
			t.Fatalf("missing content payload: %#v", payload["content"])
		}
		text, _ := content["text"].(string)
		received <- text

		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":0,"msg":"success"}`))
	}))
	defer server.Close()

	manager := NewManager(config.NotifyConfig{
		Feishu: config.FeishuConfig{
			Enabled:    false,
			WebhookURL: server.URL,
		},
	}, nil)

	if err := manager.TestChannel(context.Background(), "feishu", Message{Title: "title", Body: "body"}); err != nil {
		t.Fatalf("test feishu channel: %v", err)
	}

	select {
	case text := <-received:
		if !strings.Contains(text, "title") || !strings.Contains(text, "body") {
			t.Fatalf("unexpected payload text: %q", text)
		}
	default:
		t.Fatal("expected feishu test message to be delivered")
	}
}

func TestManagerTestChannelAllowsDisabledBarkConfig(t *testing.T) {
	t.Parallel()

	received := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		received <- request.URL.EscapedPath()
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":200,"message":"success"}`))
	}))
	defer server.Close()

	manager := NewManager(config.NotifyConfig{
		Bark: config.BarkConfig{
			Enabled: false,
			PushURL: server.URL + "/token-value",
		},
	}, nil)

	if err := manager.TestChannel(context.Background(), "bark", Message{Title: "title", Body: "body"}); err != nil {
		t.Fatalf("test bark channel: %v", err)
	}

	select {
	case path := <-received:
		if path != "/token-value/title/body" {
			t.Fatalf("unexpected bark path: %q", path)
		}
	default:
		t.Fatal("expected bark test message to be delivered")
	}
}
