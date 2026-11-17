import type { InputHTMLAttributes } from "react";

type InputProps = InputHTMLAttributes<HTMLInputElement> & {
  label: string;
};

export function Input({ label, id, className = "", ...props }: InputProps) {
  return (
    <label htmlFor={id} className="flex flex-col gap-1 text-sm text-gray-700">
      {label}
      <input
        id={id}
        className={`h-8 rounded-md border border-gray-200 px-3 text-sm text-gray-900 ${className}`}
        {...props}
      />
    </label>
  );
}
