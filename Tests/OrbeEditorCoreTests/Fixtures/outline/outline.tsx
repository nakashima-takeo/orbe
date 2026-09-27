import { useEffect, useState } from "react";

type Props = {
  title: string;
  items: string[];
};

export interface Theme {
  accent: string;
}

const defaultTheme: Theme = { accent: "#0af" };

export function List({ title, items }: Props) {
  const [selected, setSelected] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => setSelected((i) => i + 1), 1000);
    return () => clearInterval(timer);
  }, []);

  function handleClick(index: number) {
    setSelected(index);
  }

  return (
    <section className="list">
      <h2>{title}</h2>
      {items.map((item, index) => (
        <button key={item} onClick={() => handleClick(index)}>
          {item}
        </button>
      ))}
    </section>
  );
}

export const Header = ({ title }: { title: string }) => {
  const upper = title.toUpperCase();
  return <h1>{upper}</h1>;
};

export class Store<T> {
  private items: T[] = [];

  add(item: T): void {
    this.items.push(item);
  }

  get size(): number {
    return this.items.length;
  }
}

export default List;
