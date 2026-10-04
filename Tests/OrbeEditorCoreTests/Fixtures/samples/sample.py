"""Line index over UTF-16 offsets."""

class LineIndex:
    def __init__(self, text: str) -> None:
        self.starts = [0]
        for i, ch in enumerate(text):
            if ch == "\n":
                self.starts.append(i + 1)

    def point(self, offset: int) -> tuple[int, int]:
        row = max(i for i, s in enumerate(self.starts) if s <= offset)
        return row, offset - self.starts[row]
