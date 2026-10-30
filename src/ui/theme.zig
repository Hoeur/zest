//! Colors (0xAARRGGBB), metrics and icons taken from the mockups in `ui/`.

pub const background: u32 = 0xFF0B0E12;
pub const sidebar: u32 = 0xFF0E1216;
pub const panel: u32 = 0xFF11161C;
pub const raised: u32 = 0xFF1A2027;
pub const border: u32 = 0xFF232B34;
pub const grid: u32 = 0xFF1C232B;

pub const text: u32 = 0xFFF2F4F7;
pub const muted: u32 = 0xFF97A1AD;

pub const amber: u32 = 0xFFFFC83D;
pub const amber_dim: u32 = 0xFF2C2415;
pub const on_amber: u32 = 0xFF17130A;
pub const green: u32 = 0xFF2FCB76;
pub const green_dim: u32 = 0xFF123D28;
pub const red: u32 = 0xFFF2545B;
pub const red_dim: u32 = 0xFF4A1A1F;
pub const blue: u32 = 0xFF4C9BFF;
pub const blue_dim: u32 = 0xFF14304F;
pub const purple: u32 = 0xFFB067F5;
pub const key: u32 = 0xFFF0C674;
pub const string: u32 = 0xFFFF8A80;

pub const sidebar_width: f32 = 245;
pub const topbar_height: f32 = 66;
pub const page_margin: f32 = 26;
pub const gap: f32 = 14;

pub const icon = struct {
    pub const home = "\u{E80F}";
    pub const link = "\u{E71B}";
    pub const layers = "\u{E81E}";
    pub const pulse = "\u{E9D9}";
    pub const chart = "\u{E9D2}";
    pub const database = "\u{EDA2}";
    pub const settings = "\u{E713}";
    pub const search = "\u{E721}";
    pub const bell = "\u{EA8F}";
    pub const chevron_down = "\u{E70D}";
    pub const play = "\u{E768}";
    pub const add = "\u{E710}";
    pub const check = "\u{E73E}";
    pub const cross = "\u{E711}";
    pub const stopwatch = "\u{E916}";
    pub const bolt = "\u{E945}";
    pub const more = "\u{E712}";
    pub const chevron_right = "\u{E76C}";
    pub const minus = "\u{E738}";
    pub const clock = "\u{E823}";
    pub const users = "\u{E716}";
    pub const file = "\u{E8A5}";
};
