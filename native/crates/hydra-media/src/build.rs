use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{
    BranchPlan, BranchTracks, ErrorCode, GraphPlan, LegacyKind, NdiDestination, NdiSource,
    RequiredMedia, SinkAdapterPlan, SourceAdapterPlan,
};

use crate::adapters::ndi_source::NdiTrack;
use crate::adapters::{ndi_sink, ndi_source, rtmp, rtp, srt, udp};
use crate::branch::{configure_queue, profiles_for, BranchHandle, QueueProfiles};
use crate::events::{EndpointDirection, Transport};
use crate::lifecycle::{FailureReason, PipelineLifecycleEmitter};
use crate::metrics::{
    add_destination_metrics_probe, destination_metrics, destination_metrics_with_drops,
    probe_buffer_size, DestMetrics,
};
use crate::output::StatsWriter;
use crate::runtime::{EndpointDescriptor, PipelineRuntime};

use thiserror::Error;

#[derive(Debug, Error)]
#[error("{code}: {detail}")]
pub struct BuildError {
    code: ErrorCode,
    detail: String,
    endpoint_ids: Vec<String>,
}

impl BuildError {
    pub fn new(code: ErrorCode, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
            endpoint_ids: Vec::new(),
        }
    }

    pub const fn code(&self) -> ErrorCode {
        self.code
    }

    pub fn detail(&self) -> &str {
        &self.detail
    }

    pub fn endpoint_ids(&self) -> &[String] {
        &self.endpoint_ids
    }

    pub(crate) fn aggregate(failures: Vec<(String, BuildError)>) -> Self {
        let first_code = failures[0].1.code;
        let code = if failures.iter().all(|(_, error)| error.code == first_code) {
            first_code
        } else {
            ErrorCode::RuntimeError
        };
        let endpoint_ids: Vec<_> = failures.iter().map(|(id, _)| id.clone()).collect();
        let failure_details = failures
            .iter()
            .map(|(id, error)| format!("{id}: {}", error.detail))
            .collect::<Vec<_>>()
            .join("; ");
        Self {
            code,
            detail: format!(
                "failed destination endpoints [{}]: {failure_details}",
                endpoint_ids.join(", ")
            ),
            endpoint_ids,
        }
    }
}

struct BuiltBranch {
    endpoint_id: String,
    bin: gst::Bin,
    input_pads: Vec<(MediaLane, gst::Pad)>,
    requested_pads: Vec<(gst::Element, gst::Pad)>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MediaLane {
    Program,
    Video,
    Audio,
}

struct GraphCore {
    runtime: PipelineRuntime,
    tees: Vec<(MediaLane, gst::Element)>,
    source_output_pads: Vec<(MediaLane, gst::Pad)>,
    ndi_readiness: Option<ndi_source::NdiReadinessMonitor>,
    endpoints: Vec<EndpointDescriptor>,
}

pub struct BuiltGraph {
    core: GraphCore,
    branches: Vec<BuiltBranch>,
}

pub struct LinkedGraph {
    core: GraphCore,
    branch_handles: Vec<(gst::Element, BranchHandle)>,
}

pub struct RunningGraph {
    runtime: PipelineRuntime,
    branch_handles: Vec<(gst::Element, BranchHandle)>,
    endpoints: Vec<EndpointDescriptor>,
}

pub fn build(
    plan: GraphPlan,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) -> Result<BuiltGraph, BuildError> {
    preflight_ndi_factories(&plan)?;
    let pipeline = gst::Pipeline::new();
    let lifecycle = PipelineLifecycleEmitter::new(writer.clone());
    let source_result = build_source_bin(&plan, writer.clone(), &lifecycle)?;
    let mut tees = Vec::with_capacity(source_result.output_pads.len());
    for (lane, _) in &source_result.output_pads {
        let name = match lane {
            MediaLane::Program => "tee",
            MediaLane::Video => "video_tee",
            MediaLane::Audio => "audio_tee",
        };
        let tee = make_element("tee", name)?;
        tee.set_property("name", name);
        tee.set_property("allow-not-linked", true);
        tees.push((*lane, tee));
    }
    if tees.is_empty() {
        return Err(BuildError::new(
            ErrorCode::UnsupportedGraph,
            "source has no media lanes",
        ));
    }

    let mut branch_results = Vec::with_capacity(plan.branches.len());
    let mut failures = Vec::new();
    for (branch_index, branch) in plan.branches.iter().enumerate() {
        match build_destination_bin(branch_index, branch, writer.clone()) {
            Ok(result) => branch_results.push((branch, result)),
            Err(error) => failures.push((branch.endpoint_id.clone(), error)),
        }
    }
    if !failures.is_empty() {
        return Err(BuildError::aggregate(failures));
    }

    pipeline
        .add(&source_result.bin)
        .map_err(|error| BuildError::new(ErrorCode::RuntimeError, error.to_string()))?;
    for (_, lane_tee) in &tees {
        pipeline
            .add(lane_tee)
            .map_err(|error| BuildError::new(ErrorCode::RuntimeError, error.to_string()))?;
    }

    let dest_metrics: Arc<Mutex<Vec<Arc<DestMetrics>>>> = Arc::new(Mutex::new(Vec::new()));
    let mut branches = Vec::with_capacity(branch_results.len());
    let mut endpoints = vec![source_result.endpoint];
    for (plan, result) in branch_results {
        pipeline
            .add(&result.bin)
            .map_err(|error| BuildError::new(ErrorCode::RuntimeError, error.to_string()))?;
        dest_metrics
            .lock()
            .map_err(|_| BuildError::new(ErrorCode::RuntimeError, "metrics mutex poisoned"))?
            .push(result.metrics);
        endpoints.push(endpoint_descriptor_for_branch(plan, &result.bin));
        branches.push(BuiltBranch {
            endpoint_id: plan.endpoint_id.clone(),
            bin: result.bin,
            input_pads: result.input_pads,
            requested_pads: result.requested_pads,
        });
    }

    let runtime = PipelineRuntime {
        pipeline,
        loop_: glib::MainLoop::new(None, false),
        source: source_result.source,
        lifecycle,
        source_bytes_total: source_result.source_bytes_total,
        source_bytes_last_interval: Arc::new(AtomicU64::new(0)),
        source_bytes_per_sec: Arc::new(AtomicU64::new(0)),
        processing_pending: source_result.processing_pending,
        dest_metrics,
        running: Arc::new(AtomicBool::new(true)),
    };

    Ok(BuiltGraph {
        core: GraphCore {
            runtime,
            tees,
            source_output_pads: source_result.output_pads,
            ndi_readiness: source_result.ndi_readiness,
            endpoints,
        },
        branches,
    })
}

impl BuiltGraph {
    pub fn link(self) -> Result<LinkedGraph, BuildError> {
        self.link_impl(None)
    }

    fn link_impl(self, injected_failure_index: Option<usize>) -> Result<LinkedGraph, BuildError> {
        for (lane, source_pad) in &self.core.source_output_pads {
            let tee = tee_for_lane(&self.core.tees, *lane)?;
            let sink_pad = tee
                .static_pad("sink")
                .ok_or_else(|| BuildError::new(ErrorCode::LinkFailed, "tee has no sink pad"))?;
            source_pad.link(&sink_pad).map_err(link_build_error)?;
        }

        let mut handles = Vec::with_capacity(self.branches.len());
        let mut failures = Vec::new();
        for (index, branch) in self.branches.into_iter().enumerate() {
            let endpoint_id = branch.endpoint_id.clone();
            match link_built_branch(
                &self.core.tees,
                branch,
                injected_failure_index == Some(index),
            ) {
                Ok(branch_handles) => handles.extend(branch_handles),
                Err(error) => failures.push((endpoint_id, error)),
            }
        }
        if !failures.is_empty() {
            release_handles(&handles);
            return Err(BuildError::aggregate(failures));
        }

        Ok(LinkedGraph {
            core: self.core,
            branch_handles: handles,
        })
    }
}

impl LinkedGraph {
    pub fn runtime(&self) -> &PipelineRuntime {
        &self.core.runtime
    }

    pub fn endpoints(&self) -> &[EndpointDescriptor] {
        &self.core.endpoints
    }

    pub fn start(self) -> Result<RunningGraph, BuildError> {
        if let Err(error) = self.core.runtime.lifecycle.emit_starting() {
            release_handles(&self.branch_handles);
            return Err(BuildError::new(ErrorCode::RuntimeError, error.to_string()));
        }
        if let Err(error) = self.core.runtime.pipeline.set_state(gst::State::Playing) {
            let _ = self
                .core
                .runtime
                .lifecycle
                .emit_failed(FailureReason::Startup);
            let _ = self.core.runtime.pipeline.set_state(gst::State::Null);
            release_handles(&self.branch_handles);
            let code = if self.core.ndi_readiness.is_some() {
                // Best effort: NDI factories were present, so an NDI graph failing its
                // initial state transition most commonly means the BYOL runtime is absent.
                ErrorCode::NdiRuntimeMissing
            } else {
                ErrorCode::RuntimeError
            };
            return Err(BuildError::new(code, error.to_string()));
        }
        if let Some(readiness) = self.core.ndi_readiness.as_ref() {
            readiness.arm(&self.core.runtime.pipeline);
        }

        Ok(RunningGraph {
            runtime: self.core.runtime,
            branch_handles: self.branch_handles,
            endpoints: self.core.endpoints,
        })
    }

    pub fn shutdown(self) -> Result<(), BuildError> {
        let state_result = self.core.runtime.pipeline.set_state(gst::State::Null);
        release_handles(&self.branch_handles);
        state_result
            .map(|_| ())
            .map_err(|error| BuildError::new(ErrorCode::Shutdown, error.to_string()))
    }
}

impl RunningGraph {
    pub fn runtime(&self) -> &PipelineRuntime {
        &self.runtime
    }

    pub fn endpoints(&self) -> &[EndpointDescriptor] {
        &self.endpoints
    }

    pub fn shutdown(self) -> Result<(), BuildError> {
        self.runtime.running.store(false, Ordering::Relaxed);
        let state_result = self.runtime.pipeline.set_state(gst::State::Null);
        release_handles(&self.branch_handles);
        state_result
            .map(|_| ())
            .map_err(|error| BuildError::new(ErrorCode::Shutdown, error.to_string()))
    }
}

struct SourceBuild {
    bin: gst::Bin,
    source: gst::Element,
    output_pads: Vec<(MediaLane, gst::Pad)>,
    ndi_readiness: Option<ndi_source::NdiReadinessMonitor>,
    endpoint: EndpointDescriptor,
    source_bytes_total: Arc<AtomicU64>,
    processing_pending: Arc<AtomicBool>,
}

fn build_source_bin(
    plan: &GraphPlan,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
    lifecycle: &PipelineLifecycleEmitter,
) -> Result<SourceBuild, BuildError> {
    // Exhaustive: a new source adapter kind is a compile error.
    match &plan.source.adapter {
        SourceAdapterPlan::Ndi { config, media } => {
            build_ndi_source_bin(plan, config, *media, lifecycle)
        }
        SourceAdapterPlan::Srt { config, .. } => {
            let source = make_element(source_element_factory(LegacyKind::Srt), "source element")?;
            srt::apply_source(&source, config).map_err(adapter_error)?;
            maybe_do_timestamp(&source);
            srt::configure_source(&source, config, writer);
            finish_program_source(plan, source, LegacyKind::Srt, lifecycle)
        }
        SourceAdapterPlan::Udp { config, .. } => {
            let source = make_element(source_element_factory(LegacyKind::Udp), "source element")?;
            udp::apply_source(&source, config).map_err(adapter_error)?;
            maybe_do_timestamp(&source);
            finish_program_source(plan, source, LegacyKind::Udp, lifecycle)
        }
        SourceAdapterPlan::Rtp { config, .. } => {
            let source = make_element(source_element_factory(LegacyKind::Rtp), "source element")?;
            rtp::apply_source(&source, config).map_err(adapter_error)?;
            maybe_do_timestamp(&source);
            finish_program_source(plan, source, LegacyKind::Rtp, lifecycle)
        }
        SourceAdapterPlan::Rtmp { config, .. } => {
            let source = make_element(source_element_factory(LegacyKind::Rtmp), "source element")?;
            rtmp::apply(&source, config).map_err(adapter_error)?;
            maybe_do_timestamp(&source);
            finish_program_source(plan, source, LegacyKind::Rtmp, lifecycle)
        }
    }
}

fn maybe_do_timestamp(element: &gst::Element) {
    if element.find_property("do-timestamp").is_some() {
        element.set_property("do-timestamp", true);
    }
}

fn finish_program_source(
    plan: &GraphPlan,
    source: gst::Element,
    transport: LegacyKind,
    lifecycle: &PipelineLifecycleEmitter,
) -> Result<SourceBuild, BuildError> {
    let bin_name = format!("source_{}", sanitize_endpoint_id(&plan.source.endpoint_id));
    let bin = gst::Bin::with_name(&bin_name);

    let output_pad = match transport {
        LegacyKind::Rtp => {
            let depay = make_element("rtpmp2tdepay", "RTP depayloader")?;
            bin.add_many([&source, &depay])
                .map_err(runtime_build_error)?;
            source.link(&depay).map_err(link_build_error)?;
            depay.static_pad("src")
        }
        LegacyKind::Rtmp => {
            rtmp::build_source_contents(&bin, &source).map_err(rtmp_adapter_error)?
        }
        LegacyKind::Srt | LegacyKind::Udp => {
            bin.add(&source).map_err(runtime_build_error)?;
            source.static_pad("src")
        }
    }
    .ok_or_else(|| BuildError::new(ErrorCode::LinkFailed, "source has no output pad"))?;

    let ghost = gst::GhostPad::builder_with_target(&output_pad)
        .map_err(runtime_build_error)?
        .name("src")
        .build();
    bin.add_pad(&ghost).map_err(runtime_build_error)?;
    let bin_output_pad = ghost.upcast();

    let source_bytes_total = Arc::new(AtomicU64::new(0));
    let processing_pending = Arc::new(AtomicBool::new(true));
    let bytes_counter = source_bytes_total.clone();
    let lifecycle_ref = lifecycle.clone();
    let processing_pending_ref = processing_pending.clone();
    output_pad.add_probe(
        gst::PadProbeType::BUFFER | gst::PadProbeType::BUFFER_LIST,
        move |_pad, info| {
            if let Some(buffer_size) = probe_buffer_size(info) {
                record_source_buffer(
                    &bytes_counter,
                    &processing_pending_ref,
                    &lifecycle_ref,
                    buffer_size,
                );
            }
            gst::PadProbeReturn::Ok
        },
    );

    Ok(SourceBuild {
        bin,
        source,
        output_pads: vec![(MediaLane::Program, bin_output_pad)],
        ndi_readiness: None,
        endpoint: EndpointDescriptor {
            bin_name,
            endpoint_id: plan.source.endpoint_id.clone(),
            direction: EndpointDirection::Source,
            transport: legacy_transport(transport),
        },
        source_bytes_total,
        processing_pending,
    })
}

fn build_ndi_source_bin(
    plan: &GraphPlan,
    config: &NdiSource,
    media: RequiredMedia,
    lifecycle: &PipelineLifecycleEmitter,
) -> Result<SourceBuild, BuildError> {
    let bin_name = format!("source_{}", sanitize_endpoint_id(&plan.source.endpoint_id));
    let built = ndi_source::build(config, media, &bin_name)
        .map_err(|error| BuildError::new(error.code(), error.detail()))?;
    let output_pads = built
        .output_pads
        .into_iter()
        .map(|(track, pad)| (media_lane(track), pad))
        .collect::<Vec<_>>();
    let source_bytes_total = Arc::new(AtomicU64::new(0));
    let processing_pending = Arc::new(AtomicBool::new(true));
    for (_, output_pad) in &output_pads {
        let bytes_counter = source_bytes_total.clone();
        let lifecycle_ref = lifecycle.clone();
        let processing_pending_ref = processing_pending.clone();
        output_pad.add_probe(
            gst::PadProbeType::BUFFER | gst::PadProbeType::BUFFER_LIST,
            move |_pad, info| {
                if let Some(buffer_size) = probe_buffer_size(info) {
                    record_source_buffer(
                        &bytes_counter,
                        &processing_pending_ref,
                        &lifecycle_ref,
                        buffer_size,
                    );
                }
                gst::PadProbeReturn::Ok
            },
        );
    }

    Ok(SourceBuild {
        bin: built.bin,
        source: built.source,
        output_pads,
        ndi_readiness: Some(built.readiness),
        endpoint: EndpointDescriptor {
            bin_name,
            endpoint_id: plan.source.endpoint_id.clone(),
            direction: EndpointDirection::Source,
            transport: Transport::Ndi,
        },
        source_bytes_total,
        processing_pending,
    })
}

struct DestinationBuild {
    bin: gst::Bin,
    input_pads: Vec<(MediaLane, gst::Pad)>,
    metrics: Arc<DestMetrics>,
    requested_pads: Vec<(gst::Element, gst::Pad)>,
}

fn build_destination_bin(
    branch_index: usize,
    branch: &BranchPlan,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) -> Result<DestinationBuild, BuildError> {
    // Exhaustive: a new sink adapter kind is a compile error.
    match &branch.adapter {
        SinkAdapterPlan::Ndi { config, media } => {
            build_ndi_destination_bin(branch_index, branch, config, *media)
        }
        SinkAdapterPlan::Srt { config, .. } => {
            let sink = make_element(
                destination_element_factory(LegacyKind::Srt),
                "destination element",
            )?;
            srt::apply_destination(&sink, config).map_err(adapter_error)?;
            srt::configure_sink(&sink);
            finish_program_destination(branch_index, branch, sink, LegacyKind::Srt, writer, true)
        }
        SinkAdapterPlan::Udp { config, .. } => {
            let sink = make_element(
                destination_element_factory(LegacyKind::Udp),
                "destination element",
            )?;
            udp::apply_sink(&sink, config).map_err(adapter_error)?;
            udp::configure_sink(&sink);
            finish_program_destination(branch_index, branch, sink, LegacyKind::Udp, writer, false)
        }
        SinkAdapterPlan::Rtmp { config, .. } => {
            let sink = make_element(
                destination_element_factory(LegacyKind::Rtmp),
                "destination element",
            )?;
            rtmp::apply(&sink, config).map_err(adapter_error)?;
            rtmp::configure_sink(&sink);
            finish_program_destination(branch_index, branch, sink, LegacyKind::Rtmp, writer, false)
        }
    }
}

fn finish_program_destination(
    branch_index: usize,
    branch: &BranchPlan,
    sink: gst::Element,
    transport: LegacyKind,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
    track_srt_element: bool,
) -> Result<DestinationBuild, BuildError> {
    let bin_name = destination_bin_name(branch_index, &branch.endpoint_id);
    let bin = gst::Bin::with_name(&bin_name);
    let queue = make_element("queue", "branch queue")?;
    let QueueProfiles::Program(profile) = profiles_for(branch.queue) else {
        return Err(BuildError::new(
            ErrorCode::ConfigInvalid,
            "legacy destination requires a program queue profile",
        ));
    };
    configure_queue(&queue, profile);

    let requested_pads = if transport == LegacyKind::Rtmp {
        rtmp::build_destination_contents(&bin, &queue, &sink, writer).map_err(rtmp_adapter_error)?
    } else {
        bin.add_many([&queue, &sink]).map_err(runtime_build_error)?;
        queue.link(&sink).map_err(link_build_error)?;
        Vec::new()
    };

    let sink_pad = queue
        .static_pad("sink")
        .ok_or_else(|| BuildError::new(ErrorCode::LinkFailed, "queue has no sink pad"))?;
    let ghost = gst::GhostPad::builder_with_target(&sink_pad)
        .map_err(runtime_build_error)?
        .name("sink")
        .build();
    bin.add_pad(&ghost).map_err(runtime_build_error)?;

    let factory = destination_element_factory(transport);
    let metrics = destination_metrics(
        Some(branch.endpoint_id.clone()),
        non_empty_name(&branch.endpoint_name),
        Some(schema_for_kind(transport).to_string()),
        factory,
        track_srt_element.then_some(sink),
    );
    if let Some(src_pad) = queue.static_pad("src") {
        add_destination_metrics_probe(&src_pad, metrics.clone());
    }

    Ok(DestinationBuild {
        bin,
        input_pads: vec![(MediaLane::Program, ghost.upcast())],
        metrics,
        requested_pads,
    })
}

fn build_ndi_destination_bin(
    branch_index: usize,
    branch: &BranchPlan,
    config: &NdiDestination,
    media: BranchTracks,
) -> Result<DestinationBuild, BuildError> {
    let bin_name = destination_bin_name(branch_index, &branch.endpoint_id);
    let built = ndi_sink::build(config, media, &bin_name, profiles_for(branch.queue))
        .map_err(|error| BuildError::new(error.code(), error.detail()))?;
    let metrics = destination_metrics_with_drops(
        Some(branch.endpoint_id.clone()),
        non_empty_name(&branch.endpoint_name),
        Some("NDI".to_string()),
        "ndisink",
        Some(built.sink),
        built.drops,
    );
    for metric_pad in built.metric_pads {
        add_destination_metrics_probe(&metric_pad, metrics.clone());
    }

    Ok(DestinationBuild {
        bin: built.bin,
        input_pads: built
            .input_pads
            .into_iter()
            .map(|(track, pad)| (media_lane(track), pad))
            .collect(),
        metrics,
        requested_pads: built.requested_pads,
    })
}

fn link_built_branch(
    tees: &[(MediaLane, gst::Element)],
    branch: BuiltBranch,
    inject_failure: bool,
) -> Result<Vec<(gst::Element, BranchHandle)>, BuildError> {
    let BuiltBranch {
        bin,
        input_pads,
        mut requested_pads,
        ..
    } = branch;
    if inject_failure {
        release_requested_pads(&requested_pads);
        return Err(BuildError::new(
            ErrorCode::LinkFailed,
            "injected branch link failure",
        ));
    }
    if input_pads.is_empty() {
        release_requested_pads(&requested_pads);
        return Err(BuildError::new(
            ErrorCode::UnsupportedGraph,
            "destination branch has no media lanes",
        ));
    }

    let mut handles = Vec::with_capacity(input_pads.len());
    for (index, (lane, sink_pad)) in input_pads.into_iter().enumerate() {
        let tee = match tee_for_lane(tees, lane) {
            Ok(tee) => tee,
            Err(error) => {
                release_handles(&handles);
                release_requested_pads(&requested_pads);
                return Err(error);
            }
        };
        let tee_pad = match tee.request_pad_simple("src_%u") {
            Some(pad) => pad,
            None => {
                release_handles(&handles);
                release_requested_pads(&requested_pads);
                return Err(BuildError::new(
                    ErrorCode::LinkFailed,
                    "failed to request tee source pad",
                ));
            }
        };
        let handle = BranchHandle {
            bin: bin.clone(),
            tee_pad,
            requested_pads: if index == 0 {
                std::mem::take(&mut requested_pads)
            } else {
                Vec::new()
            },
        };
        if let Err(error) = handle.tee_pad.link(&sink_pad) {
            handle.shutdown(tee);
            release_handles(&handles);
            release_requested_pads(&requested_pads);
            return Err(link_build_error(error));
        }
        handles.push((tee.clone(), handle));
    }
    Ok(handles)
}

fn release_handles(handles: &[(gst::Element, BranchHandle)]) {
    for (tee, handle) in handles.iter().rev() {
        handle.shutdown(tee);
    }
}

fn release_requested_pads(requested_pads: &[(gst::Element, gst::Pad)]) {
    for (element, pad) in requested_pads.iter().rev() {
        if let Some(peer) = pad.peer() {
            if pad.direction() == gst::PadDirection::Src {
                let _ = pad.unlink(&peer);
            } else {
                let _ = peer.unlink(pad);
            }
        }
        element.release_request_pad(pad);
    }
}

fn tee_for_lane(
    tees: &[(MediaLane, gst::Element)],
    lane: MediaLane,
) -> Result<&gst::Element, BuildError> {
    tees.iter()
        .find_map(|(candidate, tee)| (*candidate == lane).then_some(tee))
        .ok_or_else(|| {
            BuildError::new(
                ErrorCode::UnsupportedGraph,
                format!("source does not provide the {lane:?} media lane"),
            )
        })
}

const fn media_lane(track: NdiTrack) -> MediaLane {
    match track {
        NdiTrack::Video => MediaLane::Video,
        NdiTrack::Audio => MediaLane::Audio,
    }
}

fn make_element(factory: &str, role: &str) -> Result<gst::Element, BuildError> {
    gst::ElementFactory::make(factory).build().map_err(|error| {
        BuildError::new(
            ErrorCode::ElementMissing,
            format!("failed to create {role} from factory {factory}: {error}"),
        )
    })
}

fn preflight_ndi_factories(plan: &GraphPlan) -> Result<(), BuildError> {
    if !matches!(plan.source.adapter, SourceAdapterPlan::Ndi { .. }) {
        return Ok(());
    }

    let mut required = vec!["ndisrc", "ndisrcdemux", "ndisink"];
    if plan.branches.iter().any(|branch| {
        matches!(
            branch.adapter,
            SinkAdapterPlan::Ndi {
                media: BranchTracks {
                    video: true,
                    audio: true,
                },
                ..
            }
        )
    }) {
        required.push("ndisinkcombiner");
    }
    let missing = required
        .into_iter()
        .filter(|factory| gst::ElementFactory::find(factory).is_none())
        .collect::<Vec<_>>();
    if missing.is_empty() {
        return Ok(());
    }

    let mut endpoint_ids = Vec::with_capacity(plan.branches.len() + 1);
    endpoint_ids.push(plan.source.endpoint_id.clone());
    endpoint_ids.extend(
        plan.branches
            .iter()
            .map(|branch| branch.endpoint_id.clone()),
    );
    Err(BuildError {
        code: ErrorCode::NdiPluginMissing,
        detail: format!(
            "missing required NDI element factories: {}",
            missing.join(", ")
        ),
        endpoint_ids,
    })
}

fn source_element_factory(kind: LegacyKind) -> &'static str {
    match kind {
        LegacyKind::Srt => "srtsrc",
        LegacyKind::Udp | LegacyKind::Rtp => "udpsrc",
        LegacyKind::Rtmp => "rtmpsrc",
    }
}

fn destination_element_factory(kind: LegacyKind) -> &'static str {
    match kind {
        LegacyKind::Srt => "srtsink",
        LegacyKind::Udp => "udpsink",
        LegacyKind::Rtmp => "rtmpsink",
        LegacyKind::Rtp => "udpsink",
    }
}

fn schema_for_kind(kind: LegacyKind) -> &'static str {
    match kind {
        LegacyKind::Srt => "SRT",
        LegacyKind::Udp => "UDP",
        LegacyKind::Rtp => "RTP",
        LegacyKind::Rtmp => "RTMP",
    }
}

fn non_empty_name(name: &str) -> Option<String> {
    let trimmed = name.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn endpoint_descriptor_for_branch(branch: &BranchPlan, bin: &gst::Bin) -> EndpointDescriptor {
    EndpointDescriptor {
        bin_name: bin.name().to_string(),
        endpoint_id: branch.endpoint_id.clone(),
        direction: EndpointDirection::Destination,
        transport: match &branch.adapter {
            SinkAdapterPlan::Srt { .. } => Transport::Srt,
            SinkAdapterPlan::Udp { .. } => Transport::Udp,
            SinkAdapterPlan::Rtmp { .. } => Transport::Rtmp,
            SinkAdapterPlan::Ndi { .. } => Transport::Ndi,
        },
    }
}

fn legacy_transport(kind: LegacyKind) -> Transport {
    match kind {
        LegacyKind::Srt => Transport::Srt,
        LegacyKind::Udp => Transport::Udp,
        LegacyKind::Rtp => Transport::Rtp,
        LegacyKind::Rtmp => Transport::Rtmp,
    }
}

fn sanitize_endpoint_id(endpoint_id: &str) -> String {
    let sanitized: String = endpoint_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect();
    if sanitized.is_empty() {
        "endpoint".to_string()
    } else {
        sanitized
    }
}

fn destination_bin_name(branch_index: usize, endpoint_id: &str) -> String {
    format!("dest_{branch_index}_{}", sanitize_endpoint_id(endpoint_id))
}

fn runtime_build_error(error: impl fmt::Display) -> BuildError {
    BuildError::new(ErrorCode::RuntimeError, error.to_string())
}

fn link_build_error(error: impl fmt::Display) -> BuildError {
    BuildError::new(ErrorCode::LinkFailed, error.to_string())
}

fn rtmp_adapter_error(error: rtmp::RtmpAdapterError) -> BuildError {
    BuildError::new(error.code(), error.detail())
}

fn adapter_error((code, detail): (ErrorCode, String)) -> BuildError {
    BuildError::new(code, detail)
}

fn record_source_buffer(
    bytes_counter: &Arc<AtomicU64>,
    processing_pending: &Arc<AtomicBool>,
    lifecycle: &PipelineLifecycleEmitter,
    buffer_size: u64,
) {
    bytes_counter.fetch_add(buffer_size, Ordering::Relaxed);
    if processing_pending.swap(false, Ordering::AcqRel) {
        let _ = lifecycle.emit_processing();
    }
}

#[cfg(test)]
#[path = "build_tests.rs"]
mod tests;
