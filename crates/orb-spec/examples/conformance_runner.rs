use std::{env, fs};

fn main() {
    let path = env::args()
        .nth(1)
        .expect("usage: conformance_runner <cases.txt>");
    let contents = fs::read_to_string(&path).expect("failed to read cases.txt");
    for line in contents.lines() {
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split(':').collect();
        assert_eq!(fields.len(), 3, "malformed case line: {line}");
        let id = fields[0];
        let symbol = fields[1];
        let args: Vec<u64> = if fields[2].is_empty() {
            Vec::new()
        } else {
            fields[2]
                .split(',')
                .map(|s| s.parse::<u64>().expect("invalid u64 arg"))
                .collect()
        };
        let value = orb_spec::raw_cabi::call_u64(symbol, &args)
            .unwrap_or_else(|| panic!("unknown or arity-mismatched export: {symbol}"));
        println!("{id}:{value}");
    }
}
