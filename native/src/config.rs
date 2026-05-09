use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
pub struct PipelineConfig {
    pub source: ElementConfig,
    pub sinks: Vec<ElementConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ElementConfig {
    #[serde(rename = "type")]
    pub element_type: String,
    #[serde(flatten)]
    pub props: BTreeMap<String, Value>,
}
