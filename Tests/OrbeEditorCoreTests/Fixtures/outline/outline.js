const express = require("express");

const PORT = process.env.PORT || 3000;
var app = express(), started = false;
const [first, , ...rest] = process.argv;

class Cache {
  static #instances = 0;
  entries = new Map();
  onEvict = (key) => {
    const size = this.entries.size;
    console.log(key, size);
  };

  constructor(limit) {
    this.limit = limit;
  }

  get size() {
    return this.entries.size;
  }

  set size(value) {
    throw new Error("read-only");
  }

  lookup(key, { fallback = null } = {}) {
    for (const [k, v] of this.entries) {
      if (k === key) return v;
    }
    return fallback;
  }
}

function* range(start, end) {
  for (let i = start; i < end; i++) yield i;
}

app.get("/health", (req, res) => {
  const body = { ok: true, uptime: process.uptime() };
  res.json(body);
});

test.each([[1, 2]])("adds %i", (a, b) => {
  const sum = a + b;
});

app.listen(PORT, function onListen() {
  started = true;
});

const handlers = {
  create(item) {
    return item;
  },
  remove: function (id) {
    try {
      return id;
    } catch (error) {
      return null;
    }
  },
  ...defaults,
};

export default function () {
  return new Cache(10);
}
