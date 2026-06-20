import Link from "next/link";
import { backendHealth } from "../lib/api";

export const dynamic = "force-dynamic"; // always reflect live backend/worker status

export default async function Page() {
  let workerOnline = false;
  let backendUp = false;
  try {
    const h = await backendHealth();
    backendUp = true;
    workerOnline = h.worker_online;
  } catch {
    backendUp = false;
  }

  return (
    <>
      <nav className="nav">
        <Link href="/" className="brand">
          <span className="mark" />
          HANOMI
        </Link>
        <Link href="/try" className="btn btn-primary btn-sm">Try Hanomi →</Link>
      </nav>

      <header className="hero">
        <div className="wrap">
          <span className="crosshair" style={{ top: 90, right: 60 }} />
          <span className="crosshair" style={{ bottom: 40, left: 40 }} />

          <div className="eyebrow">
            <span className="dot" />
            <span className="mono">Intelligence layer for mechanical engineering · live on GCP · v2</span>
          </div>

          <h1 className="hero-title">
            CAD to <span className="draw">2D drawings</span> in minutes.
          </h1>

          <p className="sub">
            Generate production-ready drawings in minutes. Native CAD output.
            Assembly-aware. Your standards — ASME Y14.5 &amp; ISO 1101, full GD&amp;T.
          </p>

          <div className="hero-cta">
            <Link className="btn btn-primary" href="/try">Try Hanomi →</Link>
            <a className="btn btn-ghost" href="#how">
              See how it works
            </a>
          </div>

          <div className="readout">
            <div>
              <div className="k">Output</div>
              <div className="v">Native CAD / STEP</div>
            </div>
            <div>
              <div className="k">Standards</div>
              <div className="v">ASME · ISO · GD&amp;T</div>
            </div>
            <div>
              <div className="k">QC automated</div>
              <div className="v">90%</div>
            </div>
            <div>
              <div className="k">Turnaround</div>
              <div className="v">Minutes</div>
            </div>
          </div>
        </div>
      </header>

      <section id="how">
        <div className="wrap">
          <div className="sec-head">
            <span className="idx">[01]</span>
            <h2>2D drawings in minutes.</h2>
          </div>
          <div className="steps">
            <div className="step">
              <div className="num">STEP_01</div>
              <h3>Upload your 3D CAD model</h3>
              <p>Native CAD or STEP. Single parts or full assemblies — we keep
                your feature tree and assembly constraints intact.</p>
            </div>
            <div className="step">
              <div className="num">STEP_02</div>
              <h3>Hanomi generates the 2D drawing</h3>
              <p>Production-ready drawings with complete GD&amp;T, dimensioned to
                your standards — not a generic template.</p>
            </div>
            <div className="step">
              <div className="num">STEP_03</div>
              <h3>Send it to manufacturing</h3>
              <p>Shop-floor-ready output. Edits that used to take hours now take
                minutes.</p>
            </div>
          </div>
        </div>
      </section>

      <section>
        <div className="wrap">
          <div className="sec-head">
            <span className="idx">[02]</span>
            <h2>Engineers work faster with AI.</h2>
          </div>
          <div className="features">
            <div className="feat">
              <div className="tag">Assembly-aware</div>
              <h3>Parts or assemblies</h3>
              <p>We maintain your feature tree and assembly constraints across the
                whole model — nothing flattened, nothing lost.</p>
            </div>
            <div className="feat">
              <div className="tag">Quality</div>
              <h3>90% of QC, done</h3>
              <p>Hanomi completes the bulk of quality control automatically, so
                review is fast and edits take minutes.</p>
            </div>
            <div className="feat">
              <div className="tag">Integrations</div>
              <h3>Connect your tools</h3>
              <p>Integrates seamlessly with your CAD. Have a PLM? No problem — it
                is all integrated.</p>
            </div>
          </div>
        </div>
      </section>

      <footer>
        <div className="wrap row">
          <div>
            Hanomi.ai — 3D models → 2D drawings. San Francisco · Bangalore.
          </div>
          <div className="status-pill" title="Live status of the backend API and the email worker">
            <span className={`led ${backendUp ? "on" : "off"}`} />
            API {backendUp ? "online" : "offline"}
            <span style={{ width: 16 }} />
            <span className={`led ${workerOnline ? "on" : "off"}`} />
            Worker {workerOnline ? "online" : "offline"}
          </div>
        </div>
      </footer>
    </>
  );
}
