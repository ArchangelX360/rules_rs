use bitflags::bitflags;

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Flags: u8 {
        const A = 1;
        const B = 2;
    }
}

fn main() {
    let flags = Flags::A | Flags::B;
    println!("{}", flags.bits());
}
