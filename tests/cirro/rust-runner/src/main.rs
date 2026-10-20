//! JSON-lines adapter for the external Cirro corpus, through the public binding.
use graphqlite::Connection;
use serde_json::{json, Map, Value};
use std::io::{self, BufRead, Write};

fn request(conn: &Connection, input: Value) -> Result<Value, Box<dyn std::error::Error>> {
    let query = input["query"].as_str().unwrap_or_default();
    match input["op"].as_str() {
        Some("metadata") => {
            let caps = conn.capabilities()?;
            Ok(json!({
                "sqlite_version": rusqlite::version(),
                "capabilities": {"graphqlite_version": caps.graphqlite_version,
                                 "features": caps.features},
            }))
        }
        Some("validate") => {
            let result = conn.validate(query)?;
            Ok(json!({"valid": result.valid,
                      "error": result.diagnostic.map(|d| d.to_string())}))
        }
        Some("query") => {
            let result = conn.cypher_builder(query).params(&input["params"]).run()?;
            let mut rows = Vec::with_capacity(result.len());
            for row in &result {
                let mut values = Map::new();
                for column in row.columns() {
                    values.insert(column.clone(), serde_json::to_value(row.get_value(column))?);
                }
                rows.push(Value::Object(values));
            }
            Ok(Value::Array(rows))
        }
        _ => Err("unknown request".into()),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let extension = std::env::args().nth(1).ok_or("expected extension path")?;
    let conn = Connection::open_with_extension(":memory:", extension)?;
    let mut stdout = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let response = match serde_json::from_str(&line?)
            .map_err(Into::into)
            .and_then(|input| request(&conn, input))
        {
            Ok(value) => json!({"value": value}),
            Err(error) => json!({"error": error.to_string()}),
        };
        writeln!(stdout, "{response}")?;
        stdout.flush()?;
    }
    Ok(())
}
