// src/components/MemberList.tsx
// One page of workspace members. The members API returns at most 50 rows per
// page; paging and the total count live in the parent. Demo data at the bottom.
import { useMemo, useState } from "react";
import "./member-list.css";

export type Member = {
  id: string;
  name: string;
  email: string;
  title?: string;        // job title, optional
  website?: string;      // optional
  avatarUrl?: string;    // optional; the CDN may also 404
  role: "owner" | "admin" | "member" | "guest";
  teams?: string[];
  openTasks: number;
  storageBytes: number;
  lastActiveAt: string;  // ISO 8601
  bio?: string;
};

type Labels = {
  invite: string;        // translated button label
  searchPlaceholder: string;
};

type Props = {
  members: Member[];     // the current page only (max 50, enforced by the API)
  totalCount: number;    // across all pages
  locale: string;        // BCP 47, e.g. "en-US", "de-DE", "ar-EG"
  labels: Labels;
};

const TEAM_PREVIEW = 3;

function initials(name: string): string {
  const parts = name.split(" ");
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

function daysAgo(iso: string): string {
  const days = Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000);
  return `${days} days ago`;
}

export function MemberList({ members, totalCount, locale, labels }: Props) {
  const [query, setQuery] = useState("");
  const plural = useMemo(() => new Intl.PluralRules(locale), [locale]);
  const integer = useMemo(() => new Intl.NumberFormat(locale), [locale]);
  const gigabytes = useMemo(
    () => new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }),
    [locale],
  );

  const shown = members.filter((m) =>
    m.name.toLowerCase().includes(query.trim().toLowerCase()),
  );
  const headerCount =
    plural.select(totalCount) === "one"
      ? `${integer.format(totalCount)} member`
      : `${integer.format(totalCount)} members`;

  return (
    <section className="members" aria-label="Members">
      <header className="members-header">
        <h2 className="members-title">{headerCount}</h2>
        <input
          type="search"
          className="members-search"
          aria-label="Search members"
          placeholder={labels.searchPlaceholder}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <button type="button" className="btn-invite">
          {labels.invite}
        </button>
      </header>

      <ul className="member-list">
        {shown.map((m) => {
          const teams = m.teams ?? [];
          return (
            <li key={m.id} className="member-row">
              <img
                className="avatar"
                src={m.avatarUrl}
                alt=""
                loading="lazy"
                decoding="async"
                title={initials(m.name)}
              />
              <div className="member-text">
                <div className="member-name">{m.name}</div>
                <div className="member-title">{m.title}</div>
                <a className="member-email" href={`mailto:${m.email}`}>
                  {m.email}
                </a>
                {m.website && (
                  <a className="member-site" href={m.website}>
                    {m.website}
                  </a>
                )}
                {m.bio && <p className="member-bio">{m.bio}</p>}
                <div className="member-teams">
                  {teams.slice(0, TEAM_PREVIEW).map((t) => (
                    <span key={t} className="chip">
                      {t}
                    </span>
                  ))}
                  <span className="chip chip-more">
                    +{teams.length - TEAM_PREVIEW}
                  </span>
                </div>
              </div>
              <span className="badge-role">{m.role}</span>
              <span className="count-pill" aria-label="open tasks">
                {m.openTasks}
              </span>
              <span className="tasks-label">{m.openTasks} open tasks</span>
              <span className="storage num">
                {gigabytes.format(m.storageBytes / 1e9)} GB
              </span>
              <time className="last-active num" dateTime={m.lastActiveAt}>
                {daysAgo(m.lastActiveAt)}
              </time>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Demo data (what the component renders today in the design review)
// ---------------------------------------------------------------------------

export const demoLabels: Labels = {
  invite: "Invite",
  searchPlaceholder: "Search members",
};

export const demoMembers: Member[] = [
  {
    id: "u_01",
    name: "Maya Chen",
    email: "maya@acme.test",
    title: "Product Designer",
    website: "https://maya.design",
    avatarUrl: "https://cdn.acme.test/avatars/u_01.jpg",
    role: "owner",
    teams: ["Design", "Growth"],
    openTasks: 4,
    storageBytes: 2_300_000_000,
    lastActiveAt: "2026-10-05T14:02:00Z",
    bio: "Leads the design system and onboarding flows.",
  },
  {
    id: "u_02",
    name: "Tom Alvarez",
    email: "tom@acme.test",
    title: "Engineer",
    avatarUrl: "https://cdn.acme.test/avatars/u_02.jpg",
    role: "admin",
    teams: ["Platform"],
    openTasks: 12,
    storageBytes: 850_000_000,
    lastActiveAt: "2026-10-04T09:30:00Z",
  },
  {
    id: "u_03",
    name: "Priya Raman",
    email: "priya@acme.test",
    title: "Support",
    avatarUrl: "https://cdn.acme.test/avatars/u_03.jpg",
    role: "member",
    teams: ["Support", "Billing", "Growth", "Docs"],
    openTasks: 0,
    storageBytes: 120_000_000,
    lastActiveAt: "2026-10-03T18:45:00Z",
    bio: "Answers the inbox.",
  },
];

// <MemberList members={demoMembers} totalCount={3} locale="en-US" labels={demoLabels} />
