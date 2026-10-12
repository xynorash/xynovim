// Strings the sqlx SQL injection and the route picker look at (no crate).
async fn users(pool: &Pool) {
    let _ = sqlx::query!("SELECT id, name FROM users WHERE id = $1", 1).fetch_one(pool).await;
    let _ = sqlx::query(
        "UPDATE users
         SET name = $1
         WHERE id = $2",
    );
}

#[get("/health")]
async fn health() -> &'static str {
    "ok"
}

fn app() -> Router {
    Router::new().route("/users/:id", get(user)).route("/health", get(health))
}
