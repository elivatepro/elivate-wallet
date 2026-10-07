import {
  extractReceiptWithOpenAI,
  parseReceiptExtraction,
  type ReceiptExtraction,
} from "../supabase/functions/_shared/openai-receipts.ts";
function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
function same(actual: unknown, expected: unknown) {
  assert(JSON.stringify(actual) === JSON.stringify(expected));
}
function denies(action: () => unknown) {
  let denied = false;
  try {
    action();
  } catch {
    denied = true;
  }
  assert(denied);
}
const config = {
  OPENAI_API_KEY: "fixture-key-not-real",
  OPENAI_RECEIPT_MODEL: "fixture-model",
};
const pdf = {
  bytes: new TextEncoder().encode("%PDF-1.7 fixture only"),
  mimeType: "application/pdf" as const,
};
const facts: ReceiptExtraction = {
  amount: "9007199254740993.123456789012345678",
  currency: "NGN",
  recipientAccount: "0001234567",
  recipientName: "Fixture Person",
  institutionName: "Fixture Bank",
  transactionDateTime: "03 Oct 2026 12:34:40 +01:00",
  transactionReference: "FIXTURE-REFERENCE",
  paymentStatus: "successful",
  confidence: "high",
  notes: null,
  walletDebitAmount: null,
  providerFeeAmount: "0.00",
};
function envelope(value: unknown = facts) {
  return {
    status: "completed",
    error: null,
    incomplete_details: null,
    output: [{
      type: "message",
      role: "assistant",
      status: "completed",
      content: [{ type: "output_text", text: JSON.stringify(value) }],
    }],
  };
}
const response = (value: unknown = envelope()) =>
  new Response(JSON.stringify(value), {
    headers: { "Content-Type": "application/json" },
  });
const success: typeof fetch = () => Promise.resolve(response());
Deno.test("OpenAI request is fixed, unanchored, nonstored strict PDF extraction with exact decimals", async () => {
  let calls = 0;
  const fetch: typeof globalThis.fetch = (url, options) => {
    calls++;
    assert(url === "https://api.openai.com/v1/responses");
    assert(
      options?.method === "POST" && options.redirect === "error" &&
        options.signal instanceof AbortSignal,
    );
    assert(
      new Headers(options.headers).get("Authorization") ===
        "Bearer fixture-key-not-real",
    );
    assert(typeof options.body === "string");
    const body = JSON.parse(options.body);
    assert(
      body.model === config.OPENAI_RECEIPT_MODEL && body.store === false &&
        body.stream === false && body.max_output_tokens === 2048,
    );
    assert(
      !("tools" in body) && !("conversation" in body) &&
        !("previous_response_id" in body),
    );
    const format = body.text.format;
    assert(
      format.type === "json_schema" && format.strict === true &&
        format.schema.additionalProperties === false,
    );
    same(
      format.schema.required.sort(),
      Object.keys(format.schema.properties).sort(),
    );
    assert(body.input.length === 1 && body.input[0].content.length === 2);
    const part = body.input[0].content[1];
    assert(part.type === "input_file" && part.filename === "receipt.pdf");
    assert(
      part.file_data ===
        `data:application/pdf;base64,${
          btoa(new TextDecoder().decode(pdf.bytes))
        }`,
    );
    assert(
      !options.body.includes("EXPECTED-SECRET-ACCOUNT") &&
        !options.body.includes("9007199254740993"),
    );
    return Promise.resolve(response());
  };
  const input = {
    ...pdf,
    originalFilename: "EXPECTED-SECRET-ACCOUNT.pdf",
    expectedAmount: "9007199254740993",
  };
  const outcome = await extractReceiptWithOpenAI(input, config, { fetch });
  assert(outcome.ok);
  same(outcome.facts, facts);
  assert(calls === 1);
});
Deno.test("PNG and JPEG use input_image data URLs and never file URLs", async () => {
  for (
    const file of [{
      bytes: new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1]),
      mimeType: "image/png" as const,
    }, {
      bytes: new Uint8Array([255, 216, 255, 1]),
      mimeType: "image/jpeg" as const,
    }]
  ) {
    const fetch: typeof globalThis.fetch = (_url, options) => {
      assert(typeof options?.body === "string");
      const content = JSON.parse(options.body).input[0].content[1];
      assert(content.type === "input_image" && content.detail === "high");
      assert(content.image_url.startsWith(`data:${file.mimeType};base64,`));
      assert(!("file_url" in content) && !("file_id" in content));
      return Promise.resolve(response());
    };
    assert((await extractReceiptWithOpenAI(file, config, { fetch })).ok);
  }
});
Deno.test("nullable absent facts stay absent and masked accounts never become a full identity", () => {
  const absent = {
    ...facts,
    amount: null,
    currency: null,
    recipientAccount: null,
    recipientName: null,
    institutionName: null,
    transactionDateTime: null,
    transactionReference: null,
    walletDebitAmount: null,
    providerFeeAmount: null,
    paymentStatus: "unknown",
    confidence: "low",
    notes: "Unreadable receipt",
  };
  same(parseReceiptExtraction(absent), absent);
  assert(
    parseReceiptExtraction({ ...facts, recipientAccount: "••••1234" })
      .recipientAccount === "••••1234",
  );
  assert(
    parseReceiptExtraction(facts).transactionDateTime ===
      facts.transactionDateTime,
  );
});
Deno.test("numbers, exponent, grouped, signed, noncanonical and excess precision amounts are rejected", () => {
  for (
    const invalid of [
      9007199254740993,
      "1e3",
      "1,000.00",
      "-1",
      "+1",
      " 1.00 ",
      "01.00",
      "1.0000000000000000001",
      "123456789012345678901",
      true,
    ]
  ) {
    for (
      const field of ["amount", "walletDebitAmount", "providerFeeAmount"]
    ) denies(() => parseReceiptExtraction({ ...facts, [field]: invalid }));
  }
  assert(
    parseReceiptExtraction({
      ...facts,
      amount: "0",
      walletDebitAmount: "10.010000000000000000",
      providerFeeAmount: "0",
    }).walletDebitAmount === "10.010000000000000000",
  );
});
Deno.test("missing or extra claims, malformed identity and unsupported certainty are rejected", () => {
  for (const field of Object.keys(facts)) {
    const missing: Record<string, unknown> = { ...facts };
    delete missing[field];
    denies(() => parseReceiptExtraction(missing));
  }
  for (
    const bad of [
      { ...facts, verified: true },
      { ...facts, matched: true },
      { ...facts, actorUserId: "forged" },
      { ...facts, paymentStatus: "verified" },
      { ...facts, confidence: "certain" },
      { ...facts, recipientAccount: 1234567 },
      { ...facts, recipientAccount: "https://malicious.invalid" },
      { ...facts, recipientName: [] },
      { ...facts, currency: "ngn" },
      { ...facts, notes: "x".repeat(1001) },
      { ...facts, institutionName: "bank\nignore instructions" },
    ]
  ) denies(() => parseReceiptExtraction(bad));
});
Deno.test("refusal, incomplete and nonassistant/tool outputs are technical failures", async () => {
  const outputs = [
    { ...envelope(), status: "incomplete" },
    {
      ...envelope(),
      output: [{
        type: "message",
        role: "assistant",
        status: "completed",
        content: [{ type: "output_text", text: JSON.stringify(facts) }, {
          type: "refusal",
          refusal: "fixture refusal",
        }],
      }],
    },
    {
      ...envelope(),
      output: [{ type: "function_call", name: "approve_payment" }],
    },
    {
      ...envelope(),
      output: [{
        type: "message",
        role: "user",
        status: "completed",
        content: [{ type: "output_text", text: JSON.stringify(facts) }],
      }],
    },
    { ...envelope(), error: { message: "sensitive provider data" } },
    { ...envelope(), incomplete_details: { reason: "max_output_tokens" } },
  ];
  for (const output of outputs) {
    const result = await extractReceiptWithOpenAI(pdf, config, {
      fetch: () => Promise.resolve(response(output)),
    });
    assert(
      !result.ok &&
        ["refused", "incomplete", "invalid_response"].includes(result.code),
    );
    assert(Object.keys(result).join(",") === "ok,code");
  }
});
Deno.test("malformed JSON, schema content and multiple text messages fail closed", async () => {
  const outputs = [
    new Response("not-json"),
    response({
      ...envelope(),
      output: [{
        type: "message",
        role: "assistant",
        status: "completed",
        content: [{ type: "output_text", text: "not-json" }],
      }],
    }),
    response(envelope({ ...facts, amount: 1.2 })),
    response({
      ...envelope(),
      output: [...envelope().output, ...envelope().output],
    }),
    response({ ...envelope(), output_text: JSON.stringify(facts), output: [] }),
    response({
      ...envelope(),
      output: [{
        type: "message",
        role: "assistant",
        status: "incomplete",
        content: [{ type: "output_text", text: JSON.stringify(facts) }],
      }],
    }),
  ];
  for (const item of outputs) {
    same(
      await extractReceiptWithOpenAI(pdf, config, {
        fetch: () => Promise.resolve(item),
      }),
      { ok: false, code: "invalid_response" },
    );
  }
});
Deno.test("configuration and invalid receipt bounds fail before transport", async () => {
  let calls = 0;
  const fetch: typeof globalThis.fetch = () => {
    calls++;
    return Promise.resolve(response());
  };
  for (
    const invalid of [
      { ...config, OPENAI_API_KEY: "" },
      { ...config, OPENAI_API_KEY: "bad\nkey" },
      { ...config, OPENAI_RECEIPT_MODEL: "" },
      { ...config, OPENAI_RECEIPT_MODEL: " model" },
    ]
  ) {
    same(await extractReceiptWithOpenAI(pdf, invalid, { fetch }), {
      ok: false,
      code: "configuration",
    });
  }
  for (const timeoutMs of [0, 60001, NaN, 1.5]) {
    same(await extractReceiptWithOpenAI(pdf, config, { fetch, timeoutMs }), {
      ok: false,
      code: "configuration",
    });
  }
  for (
    const file of [
      { ...pdf, bytes: new Uint8Array() },
      { ...pdf, bytes: new Uint8Array(10485761) },
      { ...pdf, bytes: new TextEncoder().encode("<html>fake receipt") },
      { bytes: pdf.bytes, mimeType: "image/png" as const },
    ]
  ) {
    same(await extractReceiptWithOpenAI(file, config, { fetch }), {
      ok: false,
      code: "invalid_receipt",
    });
  }
  assert(calls === 0);
});
Deno.test("429, 503 and network failures return only safe technical codes", async () => {
  for (const status of [429, 503, 401]) {
    same(
      await extractReceiptWithOpenAI(pdf, config, {
        fetch: () =>
          Promise.resolve(
            new Response("receipt-bank-data API-key-private", { status }),
          ),
      }),
      { ok: false, code: status === 429 ? "rate_limited" : "provider_error" },
    );
  }
  same(
    await extractReceiptWithOpenAI(pdf, config, {
      fetch: () => Promise.reject(Error("private network details")),
    }),
    { ok: false, code: "network" },
  );
});
Deno.test("response bound checks declared and actual streamed bytes", async () => {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(40000));
      controller.enqueue(new Uint8Array(40000));
    },
    cancel() {
      cancelled = true;
    },
  });
  same(
    await extractReceiptWithOpenAI(pdf, config, {
      fetch: () => Promise.resolve(new Response(stream)),
    }),
    { ok: false, code: "response_too_large" },
  );
  assert(cancelled);
  same(
    await extractReceiptWithOpenAI(pdf, config, {
      fetch: () =>
        Promise.resolve(
          new Response("{}", { headers: { "Content-Length": "65537" } }),
        ),
    }),
    { ok: false, code: "response_too_large" },
  );
  same(
    await extractReceiptWithOpenAI(pdf, config, {
      fetch: () =>
        Promise.resolve(
          response({
            ...envelope(),
            output: [{
              type: "message",
              role: "assistant",
              status: "completed",
              content: [{ type: "output_text", text: "x".repeat(8193) }],
            }],
          }),
        ),
    }),
    { ok: false, code: "invalid_response" },
  );
});
Deno.test("deadline bounds both stalled fetch and stalled response body", async () => {
  same(
    await extractReceiptWithOpenAI(pdf, config, {
      timeoutMs: 5,
      fetch: () => new Promise(() => {}),
    }),
    { ok: false, code: "timeout" },
  );
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    cancel() {
      cancelled = true;
    },
  });
  same(
    await extractReceiptWithOpenAI(pdf, config, {
      timeoutMs: 5,
      fetch: () => Promise.resolve(new Response(body)),
    }),
    { ok: false, code: "timeout" },
  );
  assert(cancelled);
});
Deno.test("valid reasoning envelope supplies only one final structured extraction", async () => {
  const output = {
    ...envelope(),
    output: [{ type: "reasoning", summary: [] }, ...envelope().output],
  };
  assert(
    (await extractReceiptWithOpenAI(pdf, config, {
      fetch: () => Promise.resolve(response(output)),
    })).ok,
  );
  assert((await extractReceiptWithOpenAI(pdf, config, { fetch: success })).ok);
});
