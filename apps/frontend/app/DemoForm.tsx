"use client";

import { useState } from "react";

type Status = "idle" | "sending" | "ok" | "error";

export default function DemoForm() {
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState<Status>("idle");
  const [errMsg, setErrMsg] = useState("");

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setStatus("sending");
    const fd = new FormData(e.currentTarget);
    const payload = {
      first_name: String(fd.get("first_name") ?? ""),
      phone: String(fd.get("phone") ?? ""),
      email: String(fd.get("email") ?? ""),
      company: String(fd.get("company") ?? ""),
    };
    try {
      const res = await fetch("/api/leads", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error || `request failed (${res.status})`);
      }
      setStatus("ok");
    } catch (err) {
      setErrMsg(err instanceof Error ? err.message : "Something went wrong");
      setStatus("error");
    }
  }

  return (
    <>
      <button className="btn btn-primary" onClick={() => setOpen(true)}>
        Try Hanomi →
      </button>

      {open && (
        <div className="modal-overlay" onClick={() => setOpen(false)}>
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="modal-head">
              <span className="mono">// request_demo.form</span>
              <button className="x" onClick={() => setOpen(false)} aria-label="Close">
                ✕
              </button>
            </div>

            {status === "ok" ? (
              <div className="done">
                <div className="done-mark">✓</div>
                <h3>Request received.</h3>
                <p>
                  Thanks for reaching out to Hanomi. Our team will email you
                  shortly to schedule your 30–45 minute demo.
                </p>
                <button className="btn btn-ghost" onClick={() => setOpen(false)}>
                  Close
                </button>
              </div>
            ) : (
              <form onSubmit={onSubmit} className="form">
                <p className="form-lede">
                  Tell us a bit about yourself so we can stay in touch.
                </p>
                <label>
                  <span className="mono">first name *</span>
                  <input name="first_name" required placeholder="Jane" />
                </label>
                <label>
                  <span className="mono">phone number *</span>
                  <input name="phone" type="tel" required placeholder="(201) 555-0123" />
                </label>
                <label>
                  <span className="mono">email *</span>
                  <input name="email" type="email" required placeholder="name@example.com" />
                </label>
                <label>
                  <span className="mono">company *</span>
                  <input name="company" required placeholder="Acme Corporation" />
                </label>
                {status === "error" && <p className="form-err">⚠ {errMsg}</p>}
                <button className="btn btn-primary" type="submit" disabled={status === "sending"}>
                  {status === "sending" ? "Submitting…" : "Request demo →"}
                </button>
              </form>
            )}
          </div>
        </div>
      )}
    </>
  );
}
