use glob::glob;

fn main() {
    let mut build = cc::Build::new();
    for pattern in &["lwip/src/core/*.c", "lwip/src/core/ipv4/*.c"] {
        for entry in glob(pattern).expect("glob pattern") {
            if let Ok(path) = entry {
                build.file(path);
            }
        }
    }
    build.file("lwip/custom/lwip_helpers.c");
    build.include("lwip/include").include("lwip/custom").warnings(false).compile("lwip");
}
