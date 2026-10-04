import React from "react";

type Props = { title: string; dirty?: boolean };

export function FileTab({ title, dirty = false }: Props) {
  return (
    <div className="tab">
      <span>{title}</span>
      {dirty && <span className="dot" />}
    </div>
  );
}
