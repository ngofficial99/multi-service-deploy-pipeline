"use client";

import Link from "next/link";
import { useState } from "react";

type Status = "idle" | "sending" | "ok" | "error";

export default function TryPage() {
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
    <div className="try-page">
      <aside className="try-aside">
        <Link href="/" className="brand">
          <span className="mark" />
          HANOMI
        </Link>
        <div>
          <h2>Tell us a bit about yourself so we can stay in touch.</h2>
          <p>
            Schedule a demo to secure early access and discover how teams use
            Hanomi to generate shop-floor-ready 2D drawings — in minutes.
          </p>
        </div>
        <div className="meta">CAD → 2D · ASME Y14.5 · ISO 1101 · full GD&amp;T</div>
      </aside>

      <main className="try-main">
        <div className="try-card">
          {status === "ok" ? (
            <div className="done">
              <div className="done-mark"><span>✓</span></div>
              <h1>Request received.</h1>
              <p>
                Thanks for reaching out to Hanomi. Our team will email you
                shortly to schedule your 30–45 minute demo.
              </p>
              <Link href="/" className="btn btn-ghost">Back to home</Link>
            </div>
          ) : (
            <>
              <span className="mono">// request_demo</span>
              <h1>Try Hanomi</h1>
              <p className="lede">All fields required.</p>
              <form className="form" onSubmit={onSubmit}>
                <label>
                  <span className="mono">first name *</span>
                  <input name="first_name" required placeholder="Jane" autoComplete="given-name" />
                </label>
                <label>
                  <span className="mono">phone number *</span>
                  <input name="phone" type="tel" required placeholder="(201) 555-0123" autoComplete="tel" />
                </label>
                <label>
                  <span className="mono">email *</span>
                  <input name="email" type="email" required placeholder="name@example.com" autoComplete="email" />
                </label>
                <label>
                  <span className="mono">company *</span>
                  <input name="company" required placeholder="Acme Corporation" autoComplete="organization" />
                </label>
                {status === "error" && <p className="form-err">⚠ {errMsg}</p>}
                <button className="btn btn-primary" type="submit" disabled={status === "sending"}>
                  {status === "sending" ? "Submitting…" : "Request demo →"}
                </button>
              </form>
              <Link href="/" className="back-link">← Back to home</Link>
            </>
          )}
        </div>
      </main>
    </div>
  );
}
