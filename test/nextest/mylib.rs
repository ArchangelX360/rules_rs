//! Library under test, exercising the lib-unit-test shape (`rust_test(crate = ...)`).

pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::add;

    #[test]
    fn adds() {
        assert_eq!(add(2, 2), 4);
    }

    #[test]
    fn adds_negative() {
        assert_eq!(add(2, -2), 0);
    }

    #[test]
    #[ignore]
    fn ignored_by_default() {
        panic!("must not run unless ignored tests are requested");
    }
}
