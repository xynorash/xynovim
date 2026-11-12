export function List({ rows }: { rows: number[] }) {
  return (
    <div>
      <ul>
        {rows.map((r) => (
          <li key={r}>
            <b>{r < 10 ? "small" : "big"}</b>
            <Icon name="x" />
          </li>
        ))}
      </ul>
    </div>
  );
}
