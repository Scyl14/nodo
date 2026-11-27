import { useEffect, useState, type ReactNode } from "react";
import {
  BatteryMedium,
  BookOpen,
  Clock3,
  Cpu,
  House,
  KeyRound,
  Map,
  Radio,
  Settings,
  Users,
  Wifi,
} from "lucide-react";
import { ARTICLES, searchLibrary } from "@/lib/nodo/library";
import { getChatDisk } from "@/lib/nodo/disk.server";
import { formatWhen, modelTier, nowMs, useNodo, type View } from "@/lib/nodo/store";

type Tab = "home" | "llms" | "community" | "radio" | "maps" | "settings";

const TABS: { id: Tab; label: string; icon: typeof House }[] = [
  { id: "home", label: "Home", icon: House },
  { id: "llms", label: "LLMs", icon: Cpu },
  { id: "community", label: "Community", icon: Users },
  { id: "radio", label: "Radio", icon: Radio },
  { id: "maps", label: "Maps", icon: Map },
  { id: "settings", label: "Settings", icon: Settings },
];

export function Console() {
  const [tab, setTab] = useState<Tab>("home");
  const passwordHash = useNodo((state) => state.passwordHash);
  const recoveryAcknowledged = useNodo((state) => state.recoveryAcknowledged);
  const unlocked = useNodo((state) => state.unlocked);
  const view = useNodo((state) => state.view);
  const setView = useNodo((state) => state.setView);
  const neighborId = useNodo((state) => state.neighborId);
  const people = useNodo((state) => state.people);

  useEffect(() => {
    if (!useNodo.getState().neighborId) {
      useNodo.setState({ neighborId: crypto.randomUUID() });
    }
  }, []);

  useEffect(() => {
    if (view === "neighbor" && tab === "settings") setTab("home");
  }, [view, tab]);

  if (!passwordHash) return <Setup />;
  if (!recoveryAcknowledged) return <Recovery />;
  if (view === "console" && !unlocked) return <Lock />;

  const neighbor = people.find((person) => person.id === neighborId);
  const neighborInside = view === "neighbor" && neighbor?.status === "approved";
  const showApp = view === "console" || neighborInside;
  const pending = people.filter((person) => person.status === "pending").length;
  const visibleTabs = view === "console" ? TABS : TABS.filter((item) => item.id !== "settings");

  return (
    <div className="min-h-screen bg-bg text-fg">
      <header className="border-b border-border bg-surface">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-4 py-4">
          <div>
            <p className="font-mono text-xs tracking-[0.22em] text-primary">NODO</p>
            <p className="mt-1 text-sm text-muted">10.41.0.1 · local only · internet not required</p>
          </div>
          <ViewSwitch view={view} onChange={setView} />
        </div>
      </header>

      {showApp ? (
        <>
          <nav className="sticky top-0 z-10 border-b border-border bg-bg/95 backdrop-blur">
            <div className="mx-auto flex max-w-5xl gap-1 overflow-x-auto px-3 py-2">
              {visibleTabs.map((item) => {
                const Icon = item.icon;
                const active = tab === item.id;
                return (
                  <button
                    key={item.id}
                    type="button"
                    onClick={() => setTab(item.id)}
                    className={`inline-flex min-h-11 shrink-0 items-center gap-2 rounded-full px-4 text-sm ${
                      active ? "bg-primary text-primary-fg" : "text-muted hover:bg-surface hover:text-fg"
                    }`}
                  >
                    <Icon size={16} aria-hidden />
                    {item.label}
                    {item.id === "settings" && pending > 0 ? (
                      <span className="rounded-full bg-danger px-2 py-0.5 font-mono text-xs text-danger-fg">
                        {pending}
                      </span>
                    ) : null}
                  </button>
                );
              })}
            </div>
          </nav>
          <main className="mx-auto max-w-5xl px-4 py-6 pb-16">
            {tab === "home" && <Home onReview={() => setTab("settings")} />}
            {tab === "llms" && <Llms />}
            {tab === "community" && <Community />}
            {tab === "radio" && <RadioPanel />}
            {tab === "maps" && <MapsPanel />}
            {tab === "settings" && view === "console" && <SettingsPanel />}
          </main>
        </>
      ) : (
        <main className="mx-auto max-w-lg px-4 py-10">
          <Gate status={neighbor?.status} />
        </main>
      )}
    </div>
  );
}

function ViewSwitch({ view, onChange }: { view: View; onChange: (view: View) => void }) {
  return (
    <div className="inline-flex rounded-full border border-border bg-bg p-1" role="group" aria-label="Viewing as">
      {(
        [
          ["console", "Console"],
          ["neighbor", "Neighbor"],
        ] as const
      ).map(([id, label]) => (
        <button
          key={id}
          type="button"
          onClick={() => onChange(id)}
          className={`min-h-11 rounded-full px-4 text-sm ${view === id ? "bg-surface-2 text-fg" : "text-muted"}`}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

function Field({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  return (
    <label className="block text-sm text-muted">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  );
}

const inputClass =
  "min-h-11 w-full rounded-lg border border-border bg-bg px-3 text-fg outline-none focus:border-primary";

function Setup() {
  const setup = useNodo((state) => state.setup);
  const [error, setError] = useState("");

  return (
    <Screen title="Set the owner password" lede="Type this on the machine itself. It is not asked over Wi-Fi.">
      <form
        className="grid gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          const data = new FormData(event.currentTarget);
          const password = String(data.get("password") ?? "");
          const again = String(data.get("again") ?? "");
          if (password.length < 8) {
            setError("Use at least 8 characters.");
            return;
          }
          if (password !== again) {
            setError("The two passwords do not match.");
            return;
          }
          setup(password);
        }}
      >
        <Field label="Password">
          <input className={inputClass} name="password" type="password" autoComplete="new-password" required />
        </Field>
        <Field label="Repeat password">
          <input className={inputClass} name="again" type="password" autoComplete="new-password" required />
        </Field>
        {error ? <p className="text-sm text-danger">{error}</p> : null}
        <button type="submit" className="min-h-11 rounded-lg bg-primary px-4 font-medium text-primary-fg">
          Continue
        </button>
      </form>
    </Screen>
  );
}

function Recovery() {
  const code = useNodo((state) => state.recoveryCode);
  const acknowledge = useNodo((state) => state.acknowledgeRecovery);
  const [checked, setChecked] = useState(false);

  return (
    <Screen title="Write down the recovery code" lede="There is no email reset. If you lose the password and this code, the console stays locked.">
      <p className="rounded-lg border border-border bg-bg px-4 py-4 text-center font-mono text-lg tracking-wide text-primary">
        {code}
      </p>
      <label className="mt-4 flex min-h-11 items-center gap-3 text-sm text-fg">
        <input type="checkbox" checked={checked} onChange={(event) => setChecked(event.target.checked)} />
        I wrote this on paper.
      </label>
      <button
        type="button"
        disabled={!checked}
        onClick={acknowledge}
        className="mt-4 min-h-11 w-full rounded-lg bg-primary px-4 font-medium text-primary-fg disabled:opacity-40"
      >
        Open the console
      </button>
    </Screen>
  );
}

function Lock() {
  const unlock = useNodo((state) => state.unlock);
  const unlockWithRecovery = useNodo((state) => state.unlockWithRecovery);
  const [useCode, setUseCode] = useState(false);
  const [error, setError] = useState("");

  return (
    <Screen title="Console locked" lede="Neighbors stay on the request page. This screen is for the owner.">
      <form
        className="grid gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          const data = new FormData(event.currentTarget);
          const ok = useCode
            ? unlockWithRecovery(String(data.get("code") ?? ""))
            : unlock(String(data.get("password") ?? ""));
          if (!ok) setError(useCode ? "That recovery code does not match." : "Wrong password.");
        }}
      >
        {useCode ? (
          <Field label="Recovery code">
            <input className={inputClass} name="code" autoComplete="off" />
          </Field>
        ) : (
          <Field label="Password">
            <input className={inputClass} name="password" type="password" autoComplete="current-password" />
          </Field>
        )}
        {error ? <p className="text-sm text-danger">{error}</p> : null}
        <button type="submit" className="min-h-11 rounded-lg bg-primary px-4 font-medium text-primary-fg">
          Unlock
        </button>
        <button type="button" className="min-h-11 text-sm text-muted underline" onClick={() => setUseCode((value) => !value)}>
          {useCode ? "Use the password" : "Use the recovery code"}
        </button>
      </form>
    </Screen>
  );
}

function Screen({ title, lede, children }: { title: string; lede: string; children: ReactNode }) {
  return (
    <main className="grid min-h-screen place-items-center bg-bg px-4 py-10 text-fg">
      <section className="w-full max-w-md rounded-2xl border border-border bg-surface p-6">
        <p className="font-mono text-xs tracking-[0.22em] text-primary">NODO</p>
        <h1 className="mt-3 text-2xl font-medium leading-tight">{title}</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted">{lede}</p>
        <div className="mt-6">{children}</div>
      </section>
    </main>
  );
}

function Gate({ status }: { status?: "pending" | "approved" | "rejected" }) {
  const requestAccess = useNodo((state) => state.requestAccess);

  if (status === "pending") {
    return (
      <Card title="Waiting for the owner" text="Your name is on the console. Nothing else on this node opens until they accept." />
    );
  }
  if (status === "rejected") {
    return (
      <div className="grid gap-4">
        <Card title="Not accepted" text="The owner refused this device. You can ask again with the same or another name." />
        <NameForm onSubmit={requestAccess} />
      </div>
    );
  }
  return (
    <div className="grid gap-4">
      <Card
        title="Ask to enter"
        text="This Wi-Fi is the node. A password for the network is not enough. The owner accepts people one by one."
      />
      <NameForm onSubmit={requestAccess} />
    </div>
  );
}

function NameForm({ onSubmit }: { onSubmit: (name: string) => void }) {
  const [error, setError] = useState("");
  return (
    <form
      className="grid gap-3"
      onSubmit={(event) => {
        event.preventDefault();
        const name = String(new FormData(event.currentTarget).get("name") ?? "").trim();
        if (!name) {
          setError("Write the name the owner should see.");
          return;
        }
        setError("");
        onSubmit(name);
      }}
    >
      <Field label="Your name">
        <input className={inputClass} name="name" placeholder="Ada, upstairs" required />
      </Field>
      {error ? <p className="text-sm text-danger">{error}</p> : null}
      <button type="submit" className="min-h-11 rounded-lg bg-primary px-4 font-medium text-primary-fg">
        Request access
      </button>
    </form>
  );
}

function Card({ title, text, children }: { title: string; text?: string; children?: ReactNode }) {
  return (
    <section className="rounded-2xl border border-border bg-surface p-5">
      <h2 className="text-lg font-medium">{title}</h2>
      {text ? <p className="mt-2 text-sm leading-relaxed text-muted">{text}</p> : null}
      {children}
    </section>
  );
}

function useBatteryLabel() {
  const [label, setLabel] = useState("Not reported");

  useEffect(() => {
    type Reading = {
      level: number;
      charging: boolean;
      addEventListener: (type: string, listener: () => void) => void;
      removeEventListener: (type: string, listener: () => void) => void;
    };
    const batteryApi = navigator as Navigator & { getBattery?: () => Promise<Reading> };
    if (!batteryApi.getBattery) return;
    let stop = () => {};
    let cancelled = false;
    batteryApi
      .getBattery()
      .then((battery) => {
        if (cancelled) return;
        const read = () => {
          const percent = Math.round(battery.level * 100);
          setLabel(battery.charging ? `${percent}% charging` : `${percent}%`);
        };
        read();
        battery.addEventListener("levelchange", read);
        battery.addEventListener("chargingchange", read);
        stop = () => {
          battery.removeEventListener("levelchange", read);
          battery.removeEventListener("chargingchange", read);
        };
      })
      .catch(() => {
        if (!cancelled) setLabel("Not reported");
      });
    return () => {
      cancelled = true;
      stop();
    };
  }, []);

  return label;
}

function Home({ onReview }: { onReview: () => void }) {
  const posts = useNodo((state) => state.posts);
  const addPost = useNodo((state) => state.addPost);
  const people = useNodo((state) => state.people);
  const clockOffsetMs = useNodo((state) => state.clockOffsetMs);
  const ramGb = useNodo((state) => state.ramGb);
  const view = useNodo((state) => state.view);
  const battery = useBatteryLabel();
  const [, tick] = useState(0);
  const pending = people.filter((person) => person.status === "pending").length;
  const tier = modelTier(ramGb);

  useEffect(() => {
    const id = window.setInterval(() => tick((value) => value + 1), 30000);
    return () => window.clearInterval(id);
  }, []);

  const clock = formatWhen(nowMs(clockOffsetMs));

  return (
    <div className="grid gap-4">
      <div className="grid gap-3 sm:grid-cols-3">
        <Stat
          icon={BatteryMedium}
          label="Battery"
          value={battery}
          note={battery === "Not reported" ? "This computer did not share one" : "This computer"}
        />
        <Stat
          icon={Clock3}
          label="Clock"
          value={clock}
          note={view === "console" ? "Set by hand in Settings if it drifts" : "The owner sets this if it drifts"}
        />
        <Stat icon={Wifi} label="Address" value="10.41.0.1" note="Wi-Fi name Nodo" />
      </div>
      {view === "console" && pending > 0 ? (
        <button type="button" onClick={onReview} className="rounded-2xl border border-primary bg-surface px-5 py-4 text-left">
          <span className="font-medium text-primary">{pending} waiting</span>
          <span className="mt-1 block text-sm text-muted">Someone asked to use this node. Review them in Settings.</span>
        </button>
      ) : null}
      <Card title="Board" text="Short notes for people already on this Wi-Fi. Phones farther away use Bitchat or Meshtastic.">
        <div className="mt-4 flex flex-wrap gap-2">
          {["I'm okay", "Need water", "Meet at 18:00"].map((phrase) => (
            <button
              key={phrase}
              type="button"
              onClick={() => addPost(phrase)}
              className="min-h-11 rounded-full border border-border px-4 text-sm text-fg hover:border-primary"
            >
              {phrase}
            </button>
          ))}
        </div>
        <form
          className="mt-3 flex gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            const data = new FormData(event.currentTarget);
            addPost(String(data.get("note") ?? ""));
            event.currentTarget.reset();
          }}
        >
          <input className={inputClass} name="note" placeholder="Write a short note" aria-label="Note" />
          <button type="submit" className="min-h-11 shrink-0 rounded-lg bg-primary px-4 text-sm font-medium text-primary-fg">
            Post
          </button>
        </form>
        <ul className="mt-4 grid gap-3">
          {posts.length === 0 ? <li className="text-sm text-muted">No notes yet.</li> : null}
          {posts.map((post) => (
            <li key={post.id} className="rounded-lg bg-bg px-3 py-3">
              <p className="text-sm">{post.body}</p>
              <p className="mt-1 font-mono text-xs text-muted">
                {post.author} · {formatWhen(post.at)}
              </p>
            </li>
          ))}
        </ul>
      </Card>
      <Card title="What is running" text={`${tier.name}. ${tier.detail} LoRa radio, FM receiver, and GPS are not connected in this preview.`}>
        <p className="mt-3 flex items-start gap-2 text-sm text-muted">
          <BookOpen size={16} className="mt-0.5 shrink-0" aria-hidden />
          The library has {ARTICLES.length} short local notes. Search them under LLMs. A model reply is not invented here.
        </p>
      </Card>
    </div>
  );
}

function Stat({ icon: Icon, label, value, note }: { icon: typeof Clock3; label: string; value: string; note: string }) {
  return (
    <div className="rounded-2xl border border-border bg-surface p-4">
      <div className="flex items-center gap-2 text-xs tracking-wide text-muted">
        <Icon size={14} aria-hidden />
        {label}
      </div>
      <p className="mt-2 font-mono text-lg text-fg">{value}</p>
      <p className="mt-1 text-xs text-muted">{note}</p>
    </div>
  );
}

function Llms() {
  const ramGb = useNodo((state) => state.ramGb);
  const [query, setQuery] = useState("");
  const tier = modelTier(ramGb);
  const hits = searchLibrary(query);

  return (
    <div className="grid gap-4">
      <Card title="Local model" text="Chat stays off until a real model file is on the machine. This preview will not pretend to answer.">
        <p className="mt-3 font-mono text-sm text-primary">{tier.name}</p>
        <p className="mt-1 text-sm text-muted">{tier.detail} First boot reads the real RAM. Here, Settings can change the sample.</p>
      </Card>
      <Card title="Library" text="These notes live on disk. They are an aid, never a substitute for a clinician or a trained technician.">
        <form className="mt-4" onSubmit={(event) => event.preventDefault()}>
          <input
            className={inputClass}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search water, bleeding, power, radio"
            aria-label="Search the library"
          />
        </form>
        <ul className="mt-4 grid gap-3">
          {hits.length === 0 ? <li className="text-sm text-muted">Nothing in the local library matches that.</li> : null}
          {hits.map((article) => (
            <li key={article.id} className="rounded-lg bg-bg px-3 py-3">
              <p className="font-mono text-xs text-primary">{article.topic}</p>
              <h3 className="mt-1 text-base font-medium">{article.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-muted">{article.body}</p>
            </li>
          ))}
        </ul>
      </Card>
    </div>
  );
}

function Community() {
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card
        title="Bitchat"
        text="Phone to phone over Bluetooth. No extra hardware. Range is short, longer only if other phones sit in between and relay."
      >
        <dl className="mt-4 grid gap-2 text-sm">
          <Row label="Cached APK" value="Not downloaded" />
          <Row label="Source" value="Official GitHub release only" />
          <Row label="Checksum" value="Checked before anyone can install it" />
        </dl>
        <p className="mt-4 text-sm leading-relaxed text-muted">
          When the node has internet it saves the signed Android APK and verifies the published checksum. Offline, neighbors download that saved file from this page. iPhone cannot install an APK. Install Bitchat from the App Store while a network still exists.
        </p>
        <p className="mt-3 rounded-lg border border-dashed border-border px-3 py-3 text-sm text-muted">
          Download stays disabled until a verified file is on disk.
        </p>
      </Card>
      <Card
        title="Meshtastic"
        text="Longer range, text only. Each person needs a LoRa board. The phone is the screen. This computer joins the mesh only with its own LoRa radio plugged in."
      >
        <p className="mt-4 rounded-lg bg-bg px-3 py-3 text-sm text-fg">Radio not connected.</p>
        <p className="mt-3 text-sm leading-relaxed text-muted">
          Meshtastic cannot carry this console. Pages stay on the Wi-Fi named Nodo. The mesh is for short messages when people are out of Wi-Fi range.
        </p>
      </Card>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b border-border py-2">
      <dt className="text-muted">{label}</dt>
      <dd className="text-right text-fg">{value}</dd>
    </div>
  );
}

function RadioPanel() {
  const presets = useNodo((state) => state.presets);
  const addPreset = useNodo((state) => state.addPreset);
  const removePreset = useNodo((state) => state.removePreset);
  const [error, setError] = useState("");

  return (
    <div className="grid gap-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <Card title="FM receiver" text="A normal computer has no FM chip. Listening needs a USB RTL-SDR and its antenna. Without it, this tab stays quiet.">
          <p className="mt-4 rounded-lg bg-bg px-3 py-3 text-sm">Receiver absent.</p>
        </Card>
        <Card title="GPS" text="No GPS device. The clock will not set itself. Set it by hand in Settings, on the console.">
          <p className="mt-4 rounded-lg bg-bg px-3 py-3 text-sm">No fix.</p>
        </Card>
      </div>
      <Card title="Stations you choose" text="FM broadcast only, 87.5 to 108 MHz. This node does not scan private or service channels.">
        <form
          className="mt-4 grid gap-3 sm:grid-cols-[1fr_8rem_auto]"
          onSubmit={(event) => {
            event.preventDefault();
            const data = new FormData(event.currentTarget);
            const message = addPreset(String(data.get("name") ?? ""), String(data.get("mhz") ?? ""));
            setError(message ?? "");
            if (!message) event.currentTarget.reset();
          }}
        >
          <input className={inputClass} name="name" placeholder="Station name" aria-label="Station name" />
          <input className={inputClass} name="mhz" placeholder="98.5" inputMode="decimal" aria-label="Frequency in megahertz" />
          <button type="submit" className="min-h-11 rounded-lg bg-primary px-4 text-sm font-medium text-primary-fg">
            Save
          </button>
        </form>
        {error ? <p className="mt-2 text-sm text-danger">{error}</p> : null}
        <ul className="mt-4 grid gap-2">
          {presets.length === 0 ? <li className="text-sm text-muted">No stations saved.</li> : null}
          {presets.map((preset) => (
            <li key={preset.id} className="flex items-center justify-between gap-3 rounded-lg bg-bg px-3 py-2">
              <span>
                {preset.name}
                <span className="ml-2 font-mono text-sm text-primary">{preset.mhz}</span>
              </span>
              <button type="button" className="min-h-11 text-sm text-muted" onClick={() => removePreset(preset.id)}>
                Remove
              </button>
            </li>
          ))}
        </ul>
      </Card>
    </div>
  );
}

function formatBytes(bytes: number) {
  if (!Number.isFinite(bytes) || bytes < 0) return "Not reported";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = value >= 10 || unit === 0 ? 0 : 1;
  return `${value.toFixed(digits)} ${units[unit]}`;
}

function useArchiveSpace() {
  const [report, setReport] = useState<"loading" | "unavailable" | { free: number; total: number; chats: number }>("loading");

  useEffect(() => {
    let cancel = false;
    getChatDisk()
      .then((disk) => {
        if (cancel) return;
        if (!Number.isFinite(disk.free) || !Number.isFinite(disk.total) || disk.total <= 0) {
          setReport("unavailable");
          return;
        }
        setReport({ free: disk.free, total: disk.total, chats: disk.chats });
      })
      .catch(() => {
        if (!cancel) setReport("unavailable");
      });
    return () => {
      cancel = true;
    };
  }, []);

  return report;
}

function ArchiveSpace() {
  const report = useArchiveSpace();
  if (report === "loading") {
    return <p className="mt-3 text-sm text-muted">Checking free space…</p>;
  }
  if (report === "unavailable") {
    return <p className="mt-3 text-sm text-muted">This machine did not report free disk space.</p>;
  }
  const used = Math.max(0, report.total - report.free);
  const usedPct = Math.min(100, Math.round((used / report.total) * 100));
  return (
    <div className="mt-4">
      <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
        <p className="font-medium">{formatBytes(report.free)} free on disk</p>
        <p className="font-mono text-xs text-muted">{formatBytes(used)} of {formatBytes(report.total)}</p>
      </div>
      <div className="mt-2 h-2 overflow-hidden rounded-full bg-bg" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={usedPct} aria-label="Disk used on the chat drive">
        <div className="h-full rounded-full bg-primary" style={{ width: `${usedPct}%` }} />
      </div>
      <p className="mt-2 text-sm text-muted">
        {report.chats > 0 ? `Saved chats use ${formatBytes(report.chats)}. ` : "No saved chats yet. "}
        Ephemeral chats are not written to disk.
      </p>
    </div>
  );
}

function MapsPanel() {
  return (
    <div className="grid gap-4">
      <Card title="Offline map" text="The installer saves one OpenStreetMap cut on the machine. The whole planet is not downloaded. This preview has no map file.">
        <p className="mt-3 text-sm text-muted">On the Debian machine the file is /var/lib/nodo/maps/region.pmtiles. OpenStreetMap contributors, via Protomaps.</p>
      </Card>
      <Card title="Meshtastic nodes" text="Pins are nodes this radio can hear, and only if they sent a position. Nodes without a position stay in a list. Nothing is invented on the map.">
        <p className="mt-3 text-sm text-muted">No radio is connected here, so there are no nodes.</p>
      </Card>
    </div>
  );
}

function SettingsPanel() {
  const people = useNodo((state) => state.people);
  const decide = useNodo((state) => state.decide);
  const recoveryCode = useNodo((state) => state.recoveryCode);
  const lock = useNodo((state) => state.lock);
  const ramGb = useNodo((state) => state.ramGb);
  const setRam = useNodo((state) => state.setRam);
  const fullscreenBoot = useNodo((state) => state.fullscreenBoot);
  const setFullscreenBoot = useNodo((state) => state.setFullscreenBoot);
  const setClock = useNodo((state) => state.setClock);
  const clockSetByHand = useNodo((state) => state.clockSetByHand);
  const clockOffsetMs = useNodo((state) => state.clockOffsetMs);

  return (
    <div className="grid gap-4">
      <Card title="People" text="Accept or refuse each device. Approved phones stay recognized. You can take access away later.">
        <ul className="mt-4 grid gap-3">
          {people.length === 0 ? <li className="text-sm text-muted">No requests yet. Open Neighbor, above, to ask as someone else.</li> : null}
          {people.map((person) => (
            <li key={person.id} className="rounded-lg bg-bg px-3 py-3">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <p className="font-medium">{person.name}</p>
                <p className="font-mono text-xs text-muted">{person.status}</p>
              </div>
              <p className="mt-1 text-xs text-muted">{formatWhen(person.requestedAt)}</p>
              <div className="mt-3 flex flex-wrap gap-2">
                <button type="button" className="min-h-11 rounded-lg bg-primary px-3 text-sm text-primary-fg" onClick={() => decide(person.id, "approved")}>
                  Accept
                </button>
                <button type="button" className="min-h-11 rounded-lg border border-border px-3 text-sm" onClick={() => decide(person.id, "rejected")}>
                  Refuse
                </button>
              </div>
            </li>
          ))}
        </ul>
      </Card>
      <Card title="Clock" text={clockSetByHand ? "Last change was made by hand." : "Still following the laptop clock. Set it if the network time is gone."}>
        <p className="mt-2 font-mono text-sm text-primary">{formatWhen(nowMs(clockOffsetMs))}</p>
        <form
          className="mt-4 flex flex-wrap gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            const when = String(new FormData(event.currentTarget).get("when") ?? "");
            const parsed = Date.parse(when);
            if (Number.isFinite(parsed)) setClock(parsed);
          }}
        >
          <input className={`${inputClass} sm:max-w-xs`} name="when" type="datetime-local" aria-label="New date and time" />
          <button type="submit" className="min-h-11 rounded-lg bg-primary px-4 text-sm font-medium text-primary-fg">
            Set clock
          </button>
        </form>
        <p className="mt-3 text-sm text-muted">GPS would set this when a receiver has a fix. None is connected.</p>
      </Card>
      <Card title="Model profile" text="Sample memory, so you can see which model first boot would pick. The small model is always kept.">
        <div className="mt-4 flex flex-wrap gap-2">
          {[4, 8, 16, 32].map((gb) => (
            <button
              key={gb}
              type="button"
              onClick={() => setRam(gb)}
              className={`min-h-11 rounded-full px-4 text-sm ${ramGb === gb ? "bg-primary text-primary-fg" : "border border-border text-fg"}`}
            >
              {gb} GB
            </button>
          ))}
        </div>
        <p className="mt-3 text-sm text-muted">{modelTier(ramGb).name}. {modelTier(ramGb).detail}</p>
      </Card>
      <Card title="Fullscreen" text="On at startup opens the dashboard fullscreen. Here the switch is saved in this browser. On Debian, the installer writes /etc/nodo/kiosk and a service reads that file.">
        <button
          type="button"
          onClick={() => setFullscreenBoot(!fullscreenBoot)}
          className={`mt-4 min-h-11 rounded-full px-4 text-sm ${fullscreenBoot ? "bg-primary text-primary-fg" : "border border-border"}`}
        >
          {fullscreenBoot ? "On at startup" : "Off at startup"}
        </button>
      </Card>
      <Card title="Chat archive" text="Disk space left where saved chats are stored. This is the machine's disk, not the browser.">
        <ArchiveSpace />
      </Card>
      <Card title="Recovery" text="Keep this on paper, not in a cloud note.">
        <p className="mt-3 flex items-center gap-2 font-mono text-primary">
          <KeyRound size={16} aria-hidden />
          {recoveryCode}
        </p>
        <button type="button" onClick={lock} className="mt-4 min-h-11 rounded-lg border border-border px-4 text-sm">
          Lock the console
        </button>
      </Card>
    </div>
  );
}
