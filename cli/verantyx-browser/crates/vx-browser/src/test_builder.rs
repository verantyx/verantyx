use wry::WebViewBuilder;

fn main() {
    let _ = WebViewBuilder::new().with_data_directory(std::path::PathBuf::from("/tmp"));
}
