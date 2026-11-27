import { createServerFn } from "@tanstack/react-start";

type Turn = { role: "user" | "assistant"; content: string };

export const askModel = createServerFn({ method: "POST" })
  .inputValidator((input: { messages: Turn[] }) => {
    if (!input || !Array.isArray(input.messages) || input.messages.length === 0) {
      throw new Error("Missing the message.");
    }
    return {
      messages: input.messages.slice(-20).map((turn) => ({
        role: turn.role === "assistant" ? ("assistant" as const) : ("user" as const),
        content: String(turn.content ?? "").slice(0, 4000),
      })),
    };
  })
  .handler(async ({ data }): Promise<{ ok: true; text: string } | { ok: false; error: string }> => {
    try {
      const response = await fetch("http://127.0.0.1:8081/v1/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages: data.messages }),
      });
      if (!response.ok) return { ok: false, error: "The model did not answer." };
      const payload = (await response.json()) as { choices?: { message?: { content?: string } }[] };
      const text = payload.choices?.[0]?.message?.content;
      if (typeof text !== "string" || !text.trim()) return { ok: false, error: "The model returned nothing." };
      return { ok: true, text };
    } catch {
      return { ok: false, error: "The model is not running on this machine." };
    }
  });
