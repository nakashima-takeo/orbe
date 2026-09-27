use std::collections::HashMap;
use std::fmt;

pub const MAX_DEPTH: usize = 32;
static GREETING: &str = "hello";

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

pub struct Wrapper(pub u32);

#[derive(Debug)]
pub enum Error {
    NotFound,
    Invalid { line: usize, reason: String },
    Io(std::io::Error),
}

pub trait Shape {
    type Output;
    const SIDES: u32;
    fn area(&self) -> f64;
    fn name() -> String {
        String::from("shape")
    }
}

impl Point {
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn distance(&self, other: &Point) -> f64 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        fn square(v: f64) -> f64 {
            v * v
        }
        (square(dx) + square(dy)).sqrt()
    }
}

impl Shape for Point {
    type Output = f64;
    const SIDES: u32 = 0;

    fn area(&self) -> f64 {
        0.0
    }
}

/// A future that is always ready.

#[must_use]
// Polled once.
pub struct Ready;

impl std::future::Future for Ready {
    type Output = ();

    fn poll(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        std::task::Poll::Ready(())
    }
}

impl<T: fmt::Display> fmt::Display for Wrapper<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl !Send for Error {}

pub mod registry {
    use super::*;

    pub struct Registry {
        items: HashMap<String, Point>,
    }

    pub(crate) fn global() -> Registry {
        Registry { items: HashMap::new() }
    }
}

macro_rules! point {
    ($x:expr, $y:expr) => {
        Point::new($x, $y)
    };
}

union Bits {
    int: u32,
    float: f32,
}

fn main() {
    let origin = point!(0.0, 0.0);
    println!("{:?}", origin);
}
