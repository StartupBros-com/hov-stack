import type { ButtonHTMLAttributes } from "react";

type Variant = "primary" | "secondary" | "ghost" | "danger";

const variants: Record<Variant, string> = {
  primary: "bg-brand-600 text-white hover:bg-brand-700",
  secondary: "border border-gray-200 bg-white text-gray-900 hover:bg-gray-50",
  ghost: "text-brand-600 hover:bg-brand-50",
  danger: "bg-red-600 text-white hover:bg-red-700",
};

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
};

export function Button({ variant = "primary", className = "", ...props }: ButtonProps) {
  return (
    <button
      className={`inline-flex h-8 items-center rounded-md px-3 text-sm font-medium ${variants[variant]} ${className}`}
      {...props}
    />
  );
}
