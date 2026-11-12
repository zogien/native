//! The canvas scratch a runtime shares across its gpu-surface views.

const canvas = @import("canvas");
const canvas_limits = @import("canvas_limits.zig");
const runtime_canvas_widget_runtime = @import("canvas_widget_runtime.zig");

const max_canvas_commands_per_view = canvas_limits.max_canvas_commands_per_view;
const max_canvas_glyphs_per_view = canvas_limits.max_canvas_glyphs_per_view;
const max_canvas_diff_changes_per_view = canvas_limits.max_canvas_diff_changes_per_view;
const max_canvas_render_overrides_per_view = canvas_limits.max_canvas_render_overrides_per_view;
const max_canvas_pipelines_per_view = canvas_limits.max_canvas_pipelines_per_view;
const max_canvas_pipeline_cache_actions_per_view = canvas_limits.max_canvas_pipeline_cache_actions_per_view;
const max_canvas_path_geometries_per_view = canvas_limits.max_canvas_path_geometries_per_view;
const max_canvas_path_geometry_cache_actions_per_view = canvas_limits.max_canvas_path_geometry_cache_actions_per_view;
const max_canvas_images_per_view = canvas_limits.max_canvas_images_per_view;
const max_canvas_image_cache_actions_per_view = canvas_limits.max_canvas_image_cache_actions_per_view;
const max_canvas_layers_per_view = canvas_limits.max_canvas_layers_per_view;
const max_canvas_layer_cache_actions_per_view = canvas_limits.max_canvas_layer_cache_actions_per_view;
const max_canvas_resources_per_view = canvas_limits.max_canvas_resources_per_view;
const max_canvas_resource_cache_actions_per_view = canvas_limits.max_canvas_resource_cache_actions_per_view;
const max_canvas_visual_effects_per_view = canvas_limits.max_canvas_visual_effects_per_view;
const max_canvas_visual_effect_cache_actions_per_view = canvas_limits.max_canvas_visual_effect_cache_actions_per_view;

/// Scratch the runtime's canvas paths share across all of its gpu-surface
/// views: the widget reconcile pass of `setCanvasWidgetLayout` and the
/// frame planner's per-plan arrays. Sized by the per-view budgets in
/// `canvas_limits.zig`, since the single-threaded loop reconciles or plans
/// one view at a time. The runtime allocates it from its init-frozen
/// `owned_allocator` together with its first gpu-surface view and keeps it
/// until `deinit`, so a runtime that never shows a canvas never pays for
/// it. Reach it through `Runtime.canvasScratch()`.
pub const CanvasScratch = struct {
    // Scratch for setCanvasWidgetLayout's reconcile pass: too large for the
    // stack at the current node cap, and the event loop is single-threaded.
    canvas_widget_reconcile_nodes: [canvas_limits.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined,
    canvas_widget_source_semantics_scratch: [canvas_limits.max_canvas_widget_semantics_per_view]canvas.WidgetSemanticsNode = undefined,
    // More reconcile-pass scratch that outgrew the stack when the widget
    // budgets quadrupled (256 -> 1024 nodes): previous control/scroll/text reconcile
    // entries, the previous text byte pool, and the invalidation diff.
    canvas_widget_reconcile_control_entries: [canvas_limits.max_canvas_widget_nodes_per_view]runtime_canvas_widget_runtime.CanvasWidgetControlReconcileEntry = undefined,
    canvas_widget_reconcile_scroll_entries: [canvas_limits.max_canvas_widget_nodes_per_view]runtime_canvas_widget_runtime.CanvasWidgetSourceScrollEntry = undefined,
    canvas_widget_reconcile_text_entries: [canvas_limits.max_canvas_widget_nodes_per_view]runtime_canvas_widget_runtime.CanvasWidgetTextReconcileEntry = undefined,
    canvas_widget_reconcile_text_bytes: [canvas_limits.max_canvas_widget_text_bytes_per_view]u8 = undefined,
    canvas_widget_invalidations_scratch: [canvas_limits.max_canvas_widget_invalidations_per_view]canvas.WidgetInvalidation = undefined,
    canvas_widget_copy_scratch: runtime_canvas_widget_runtime.CanvasWidgetCopyScratch = undefined,
    canvas_frame_render_commands: [max_canvas_commands_per_view]canvas.RenderCommand = undefined,
    canvas_frame_render_batches: [max_canvas_commands_per_view]canvas.RenderBatch = undefined,
    canvas_frame_pipeline_cache_entries: [max_canvas_pipelines_per_view]canvas.RenderPipelineCacheEntry = undefined,
    canvas_frame_pipeline_cache_actions: [max_canvas_pipeline_cache_actions_per_view]canvas.RenderPipelineCacheAction = undefined,
    canvas_frame_path_geometries: [max_canvas_path_geometries_per_view]canvas.RenderPathGeometry = undefined,
    canvas_frame_path_geometry_cache_entries: [max_canvas_path_geometries_per_view]canvas.RenderPathGeometryCacheEntry = undefined,
    canvas_frame_path_geometry_cache_actions: [max_canvas_path_geometry_cache_actions_per_view]canvas.RenderPathGeometryCacheAction = undefined,
    canvas_frame_images: [max_canvas_images_per_view]canvas.RenderImage = undefined,
    canvas_frame_image_cache_entries: [max_canvas_images_per_view]canvas.RenderImageCacheEntry = undefined,
    canvas_frame_image_cache_actions: [max_canvas_image_cache_actions_per_view]canvas.RenderImageCacheAction = undefined,
    canvas_frame_layers: [max_canvas_layers_per_view]canvas.RenderLayer = undefined,
    canvas_frame_layer_cache_entries: [max_canvas_layers_per_view]canvas.RenderLayerCacheEntry = undefined,
    canvas_frame_layer_cache_actions: [max_canvas_layer_cache_actions_per_view]canvas.RenderLayerCacheAction = undefined,
    canvas_frame_resources: [max_canvas_resources_per_view]canvas.RenderResource = undefined,
    canvas_frame_resource_cache_entries: [max_canvas_resources_per_view]canvas.RenderResourceCacheEntry = undefined,
    canvas_frame_resource_cache_actions: [max_canvas_resource_cache_actions_per_view]canvas.RenderResourceCacheAction = undefined,
    canvas_frame_visual_effects: [max_canvas_visual_effects_per_view]canvas.VisualEffect = undefined,
    canvas_frame_visual_effect_cache_entries: [max_canvas_visual_effects_per_view]canvas.VisualEffectCacheEntry = undefined,
    canvas_frame_visual_effect_cache_actions: [max_canvas_visual_effect_cache_actions_per_view]canvas.VisualEffectCacheAction = undefined,
    canvas_frame_glyph_atlas_entries: [max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined,
    canvas_frame_glyph_atlas_cache_entries: [max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined,
    canvas_frame_glyph_atlas_cache_actions: [max_canvas_glyphs_per_view * 2]canvas.GlyphAtlasCacheAction = undefined,
    canvas_frame_changes: [max_canvas_diff_changes_per_view]canvas.DiffChange = undefined,
    canvas_frame_render_override_samples: [max_canvas_render_overrides_per_view]canvas.CanvasRenderOverride = undefined,
    canvas_frame_render_override_combined: [max_canvas_render_overrides_per_view]canvas.CanvasRenderOverride = undefined,
};
