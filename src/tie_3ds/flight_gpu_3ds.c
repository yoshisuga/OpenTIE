/*
 * citro3d flight renderer for the Nintendo 3DS port.
 *
 * Craft models come from the same DOS ShipModelData conversion the desktop
 * renderer uses (TieShipModelConverter_Build), and the camera from the same
 * snapshot math (TieRenderMath_BuildCamera), so placement matches desktop.
 * That projection is reverse-Z (clip z = near, w = eye depth) with +y up; the
 * 3DS top screen is rotated a quarter turn and clips z to [-1, 0], so each
 * clip matrix swaps x and y and negates z. citro3d's default depth map then
 * writes near / depth, and GREATER keeps the nearer surface.
 *
 * Faces are lit the classic way: the vertex shader turns the face's dot
 * product with the snapshot light into a materialcolors ramp position (flat
 * faces exact, Gouraud faces smooth), and a 16 x 64 lookup texture of the
 * ramps through the current palette gives the colour (see
 * shaders/flight.v.pica).
 *
 * Not yet: markings, rotating parts, lasers, debris, sprites and sky.
 */
#include "tie_3ds/flight_gpu_3ds.h"

#include "tie/drawpol.h"
#include "tie_3ds_flight_shbin.h"
#include "tie_remaster/flight/render_math.h"
#include "tie_runtime/flight_assets/service.h"
#include "tie_runtime/flight_assets/ship_model_converter.h"
#include "tie_runtime/flight_assets/source.h"
#include "tie_runtime/runtime/flight_screen.h"
#include "tie_runtime/snapshot/snapshot.h"

#include "aeron/log.h"

#include <3ds.h>
#include <citro2d.h>
#include <citro3d.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum {
	TIE_3DS_FLIGHT_SPECIES = 256,
	TIE_3DS_TOP_SCREEN_WIDTH = 400,
	TIE_3DS_TOP_SCREEN_HEIGHT = 240,
	TIE_3DS_MATERIAL_SHADES = 16,
	TIE_3DS_MATERIAL_ROWS = 45,
	TIE_3DS_RAMP_TEXTURE_WIDTH = 16,
	TIE_3DS_RAMP_TEXTURE_HEIGHT = 64,
};

#define TIE_3DS_CLASSIC_VERTEX_TO_WORLD_UNITS 0.5f /* tie_remaster/flight/renderer_internal.h */

typedef struct TieN3dsFlightVertex {
	float position[3];
	float normal[3];        /* face normal */
	float corner_normal[3]; /* smoothed normal for Gouraud faces */
	float ramp_row;         /* lookup texture t of the face's materialcolors row */
	float gouraud;          /* 1 if the face is Gouraud-eligible */
} TieN3dsFlightVertex;

typedef struct TieN3dsSpeciesMesh {
	bool tried;
	TieN3dsFlightVertex* vertices; /* linear memory, one triangle per three */
	uint32_t vertex_count;
	float craft_scale;
} TieN3dsSpeciesMesh;

static struct {
	bool initialized;
	bool failed;
	DVLB_s* shader_binary;
	shaderProgram_s program;
	int clip_uniform;
	int light_uniform;
	int shading_uniform;
	C3D_Tex ramp_texture;
	TieN3dsSpeciesMesh meshes[TIE_3DS_FLIGHT_SPECIES];
	unsigned drawn_count;
} s_flight_gpu;

unsigned TieN3dsFlightGpu_DrawnCount(void) { return s_flight_gpu.drawn_count; }

static bool TieN3dsFlightGpu_Init(void) {
	if (s_flight_gpu.initialized || s_flight_gpu.failed)
		return s_flight_gpu.initialized;
	s_flight_gpu.failed = true;
	s_flight_gpu.shader_binary = DVLB_ParseFile((u32*)tie_3ds_flight_shbin, tie_3ds_flight_shbin_size);
	if (!s_flight_gpu.shader_binary)
		return false;
	shaderProgramInit(&s_flight_gpu.program);
	shaderProgramSetVsh(&s_flight_gpu.program, &s_flight_gpu.shader_binary->DVLE[0]);
	s_flight_gpu.clip_uniform = shaderInstanceGetUniformLocation(s_flight_gpu.program.vertexShader, "clip");
	s_flight_gpu.light_uniform = shaderInstanceGetUniformLocation(s_flight_gpu.program.vertexShader, "light");
	s_flight_gpu.shading_uniform = shaderInstanceGetUniformLocation(s_flight_gpu.program.vertexShader, "shading");
	if (!C3D_TexInit(&s_flight_gpu.ramp_texture, TIE_3DS_RAMP_TEXTURE_WIDTH, TIE_3DS_RAMP_TEXTURE_HEIGHT,
					 GPU_RGBA8)) {
		shaderProgramFree(&s_flight_gpu.program);
		DVLB_Free(s_flight_gpu.shader_binary);
		return false;
	}
	/* Linear along the ramp smooths Gouraud faces; flat faces and rows sample
	 * texel centres, so they stay exact. */
	C3D_TexSetFilter(&s_flight_gpu.ramp_texture, GPU_LINEAR, GPU_LINEAR);
	C3D_TexSetWrap(&s_flight_gpu.ramp_texture, GPU_CLAMP_TO_EDGE, GPU_CLAMP_TO_EDGE);
	s_flight_gpu.failed = false;
	s_flight_gpu.initialized = true;
	return true;
}

void TieN3dsFlightGpu_Shutdown(void) {
	if (!s_flight_gpu.initialized)
		return;
	for (int i = 0; i < TIE_3DS_FLIGHT_SPECIES; ++i)
		if (s_flight_gpu.meshes[i].vertices)
			linearFree(s_flight_gpu.meshes[i].vertices);
	C3D_TexDelete(&s_flight_gpu.ramp_texture);
	shaderProgramFree(&s_flight_gpu.program);
	DVLB_Free(s_flight_gpu.shader_binary);
	memset(&s_flight_gpu, 0, sizeof s_flight_gpu);
}

/* Rows are stored top-first, which the GPU samples at t = 1 - (row + 0.5)/64
 * (the same orientation as the presenter's frame textures). */
static float TieN3dsFlightGpu_RampRow(const TieFlightVertex* vertex) {
	int row = (int)vertex->material_id;
	if (row < 0 || row >= TIE_3DS_MATERIAL_ROWS)
		row = 0;
	return 1.0f - ((float)row + 0.5f) / (float)TIE_3DS_RAMP_TEXTURE_HEIGHT;
}

/* Within an 8x8 tile, texel bits interleave as y2 x2 y1 x1 y0 x0. */
static uint32_t TieN3dsFlightGpu_TexelIndex(uint32_t x, uint32_t y, uint32_t width) {
	const uint32_t morton = (x & 1u) | ((x & 2u) << 1) | ((x & 4u) << 2) | ((y & 1u) << 1) | ((y & 2u) << 2) |
							((y & 4u) << 3);
	return (y >> 3) * width * 8u + (x & ~7u) * 8u + morton;
}

/* materialcolors through the snapshot palette (0xAARRGGBB) into the tiled
 * RGBA8 lookup texture: column = ramp entry, row = material. Rebuilt every
 * frame so palette fades follow. */
static void TieN3dsFlightGpu_UpdateRampTexture(const uint32_t* palette) {
	uint32_t* texels = (uint32_t*)s_flight_gpu.ramp_texture.data;
	for (uint32_t row = 0; row < TIE_3DS_MATERIAL_ROWS; ++row)
		for (uint32_t entry = 0; entry < TIE_3DS_MATERIAL_SHADES; ++entry) {
			const uint32_t argb = palette[materialcolors[row * TIE_3DS_MATERIAL_SHADES + entry]];
			texels[TieN3dsFlightGpu_TexelIndex(entry, row, TIE_3DS_RAMP_TEXTURE_WIDTH)] =
				((argb & 0x00FFFFFFu) << 8) | 0xFFu;
		}
	GSPGPU_FlushDataCache(texels, s_flight_gpu.ramp_texture.size);
}

static const TieN3dsSpeciesMesh* TieN3dsFlightGpu_SpeciesMesh(uint16_t species) {
	if (species == 0 || species >= TIE_3DS_FLIGHT_SPECIES)
		return NULL;
	TieN3dsSpeciesMesh* mesh = &s_flight_gpu.meshes[species];
	if (mesh->vertices)
		return mesh;
	if (mesh->tried)
		return NULL;
	mesh->tried = true;

	const TieFlightAssetSource* source = TieFlightAssets_CurrentSource();
	uint8_t* bytes = NULL;
	size_t size = 0;
	char error[256];
	if (!source || !TieFlightAssetSource_ReadModel(source, species, &bytes, &size, NULL, error, sizeof error))
		return NULL;
	TieFlightShipModel model = { 0 };
	const bool built = TieShipModelConverter_Build(bytes, size, 90.0f, &model);
	free(bytes);
	if (!built || !model.vertex_count || !model.index_count) {
		if (built)
			TieShipModelConverter_Free(&model);
		return NULL;
	}
	mesh->vertices = (TieN3dsFlightVertex*)linearAlloc(model.index_count * sizeof(TieN3dsFlightVertex));
	if (!mesh->vertices) {
		TieShipModelConverter_Free(&model);
		return NULL;
	}
	for (uint32_t i = 0; i < model.index_count; ++i) {
		const TieFlightVertex* source_vertex = &model.vertices[model.indices[i]];
		TieN3dsFlightVertex* out = &mesh->vertices[i];
		memcpy(out->position, source_vertex->pos, sizeof out->position);
		memcpy(out->normal, source_vertex->normal, sizeof out->normal);
		memcpy(out->corner_normal, source_vertex->vertex_normal, sizeof out->corner_normal);
		out->ramp_row = TieN3dsFlightGpu_RampRow(source_vertex);
		/* Converter face_flags bit 0: the face flag byte has 0x40. */
		out->gouraud = ((int)source_vertex->face_flags & 1) ? 1.0f : 0.0f;
	}
	mesh->vertex_count = model.index_count;
	mesh->craft_scale = TIE_3DS_CLASSIC_VERTEX_TO_WORLD_UNITS * (model.model_scale_shift == 2 ? 4.0f : 1.0f);
	TieShipModelConverter_Free(&model);
	GSPGPU_FlushDataCache(mesh->vertices, mesh->vertex_count * sizeof(TieN3dsFlightVertex));
	Aeron_LogInfo("tie.3ds", "GPU mesh for species %u: %lu vertices", (unsigned)species,
				  (unsigned long)mesh->vertex_count);
	return mesh;
}

static bool TieN3dsFlightGpu_DrawsGenus(uint8_t genus) {
	return genus <= TIE_GENUS_PLATFORM || genus == TIE_GENUS_MINE || genus == TIE_GENUS_GATE;
}

/* Desktop clip (row-major, x right, y up, reverse-Z) to the 3DS top screen:
 * x' = y, y' = -x, z' = -z. */
static void TieN3dsFlightGpu_ToScreenClip(const float clip[16], C3D_Mtx* out) {
	const float* row_x = &clip[0];
	const float* row_y = &clip[4];
	const float* row_z = &clip[8];
	const float* row_w = &clip[12];
	for (int column = 0; column < 4; ++column) {
		out->r[0].c[3 - column] = row_y[column];
		out->r[1].c[3 - column] = -row_x[column];
		out->r[2].c[3 - column] = -row_z[column];
		out->r[3].c[3 - column] = row_w[column];
	}
}

static void TieN3dsFlightGpu_BeginState(void) {
	C3D_BindProgram(&s_flight_gpu.program);
	C3D_AttrInfo* attributes = C3D_GetAttrInfo();
	AttrInfo_Init(attributes);
	AttrInfo_AddLoader(attributes, 0, GPU_FLOAT, 3);
	AttrInfo_AddLoader(attributes, 1, GPU_FLOAT, 3);
	AttrInfo_AddLoader(attributes, 2, GPU_FLOAT, 3);
	AttrInfo_AddLoader(attributes, 3, GPU_FLOAT, 2);
	C3D_TexBind(0, &s_flight_gpu.ramp_texture);
	C3D_TexEnv* environment = C3D_GetTexEnv(0);
	C3D_TexEnvInit(environment);
	C3D_TexEnvSrc(environment, C3D_Both, GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0);
	C3D_TexEnvFunc(environment, C3D_Both, GPU_REPLACE);
	for (int stage = 1; stage < 6; ++stage)
		C3D_TexEnvInit(C3D_GetTexEnv(stage));
	C3D_CullFace(GPU_CULL_NONE);
	C3D_AlphaTest(false, GPU_ALWAYS, 0);
	C3D_DepthTest(true, GPU_GREATER, GPU_WRITE_ALL);
	C3D_AlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD, GPU_ONE, GPU_ZERO, GPU_ONE, GPU_ZERO);
}

void TieN3dsFlightGpu_DrawEye(int eye) {
	(void)eye;
	s_flight_gpu.drawn_count = 0;
	const TieSnapshot* snapshot = TieSnapshot_Current();
	if (!snapshot || snapshot->scene_kind != TIE_SCENE_FLIGHT || snapshot->flight_screen != TIE_FLIGHT_SCREEN_NORMAL ||
		!snapshot->flights || !TieN3dsFlightGpu_Init())
		return;

	/* Positions are taken relative to the camera, keeping float precision
	 * for nearby geometry. */
	TieFlightCamera camera;
	TieRenderMath_BuildCameraAtOrigin(&camera, &snapshot->camera, snapshot->camera.world_pos,
									  TIE_3DS_TOP_SCREEN_WIDTH, TIE_3DS_TOP_SCREEN_HEIGHT);
	TieN3dsFlightGpu_UpdateRampTexture(snapshot->palette);
	TieN3dsFlightGpu_BeginState();
	C3D_FVUnifSet(GPU_VERTEX_SHADER, s_flight_gpu.shading_uniform, snapshot->gouraudflag ? 1.0f : 0.0f, 0.0f, 0.0f,
				  0.0f);
	for (uint16_t i = 0; i < snapshot->flight_count; ++i) {
		const TieFlightObjectState* flight = &snapshot->flights[i];
		if (!TieN3dsFlightGpu_DrawsGenus(flight->genus) || (flight->flags & TIE_FOBJ_INVISIBLE))
			continue;
		/* The craft the camera rides in, unless zoomed out or replaying
		 * (as tie_remaster/flight/mesh_draw.c). */
		if (flight->slot == snapshot->camera.target_obj_slot && snapshot->camera.zoom_active == 0 &&
			snapshot->replay_mode != 2)
			continue;
		const TieN3dsSpeciesMesh* mesh = TieN3dsFlightGpu_SpeciesMesh(flight->ship_idx);
		if (!mesh)
			continue;
		const float position[3] = {
			(float)(flight->world_pos[0] - camera.origin_world[0]),
			(float)(flight->world_pos[1] - camera.origin_world[1]),
			(float)(flight->world_pos[2] - camera.origin_world[2]),
		};
		float craft_to_world[16];
		float clip[16];
		TieRenderMath_Mat4FromQuaternionTranslation(craft_to_world, flight->ori, position, mesh->craft_scale);
		TieRenderMath_Mat4Multiply(clip, camera.view_proj, craft_to_world);
		C3D_Mtx screen_clip;
		TieN3dsFlightGpu_ToScreenClip(clip, &screen_clip);
		C3D_FVUnifMtx4x4(GPU_VERTEX_SHADER, s_flight_gpu.clip_uniform, &screen_clip);
		/* World light into craft space: the transpose of the craft's
		 * rotation (row-major, columns = craft axes in world). */
		float rotation[9];
		TieRenderMath_QuaternionToRenderBasis(flight->ori, rotation);
		const float* light = snapshot->directional_dir;
		C3D_FVUnifSet(GPU_VERTEX_SHADER, s_flight_gpu.light_uniform,
					  rotation[0] * light[0] + rotation[3] * light[1] + rotation[6] * light[2],
					  rotation[1] * light[0] + rotation[4] * light[1] + rotation[7] * light[2],
					  rotation[2] * light[0] + rotation[5] * light[1] + rotation[8] * light[2], 0.0f);

		C3D_BufInfo* buffers = C3D_GetBufInfo();
		BufInfo_Init(buffers);
		BufInfo_Add(buffers, mesh->vertices, sizeof(TieN3dsFlightVertex), 4, 0x3210);
		C3D_DrawArrays(GPU_TRIANGLES, 0, (int)mesh->vertex_count);
		++s_flight_gpu.drawn_count;
	}
	/* Hand the GPU state back to citro2d. */
	C2D_Prepare();
}
