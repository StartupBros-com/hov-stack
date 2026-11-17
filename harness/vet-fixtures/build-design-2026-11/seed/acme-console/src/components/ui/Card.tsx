import type { ReactNode } from "react";

type Tone = "default" | "danger";

const tones: Record<Tone, string> = {
  default: "border-gray-200",
  danger: "border-red-200",
};

type CardProps = {
  children: ReactNode;
  tone?: Tone;
  className?: string;
};

export function Card({ children, tone = "default", className = "" }: CardProps) {
  return <section className={`rounded-lg border bg-white p-4 ${tones[tone]} ${className}`}>{children}</section>;
}

type CardHeaderProps = {
  title: string;
  description?: string;
  action?: ReactNode;
};

export function CardHeader({ title, description, action }: CardHeaderProps) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div>
        <h2 className="text-base font-semibold text-gray-900">{title}</h2>
        {description ? <p className="text-sm text-gray-500">{description}</p> : null}
      </div>
      {action}
    </div>
  );
}
