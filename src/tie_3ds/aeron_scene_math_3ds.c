/*
 * AeronScene_ComputeViewProj for the Nintendo 3DS port. The desktop
 * definition lives in aeron/src/scene/scene3d.c, which needs SDL_GPU; this is
 * a copy of it and its static helpers, so TieRenderMath_BuildCamera gives the
 * 3DS the same flight projection. Keep it in sync with scene3d.c.
 */
#include "aeron/scene/scene3d.h"

#include <math.h>
#include <string.h>

static void scene_quat_to_mat3(const float q[4], float m[9]) {
	const float w = q[0], x = q[1], y = q[2], z = q[3];
	const float xx = x * x, yy = y * y, zz = z * z;
	const float xy = x * y, xz = x * z, yz = y * z;
	const float wx = w * x, wy = w * y, wz = w * z;
	m[0] = 1.0f - 2.0f * (yy + zz);
	m[1] = 2.0f * (xy - wz);
	m[2] = 2.0f * (xz + wy);
	m[3] = 2.0f * (xy + wz);
	m[4] = 1.0f - 2.0f * (xx + zz);
	m[5] = 2.0f * (yz - wx);
	m[6] = 2.0f * (xz - wy);
	m[7] = 2.0f * (yz + wx);
	m[8] = 1.0f - 2.0f * (xx + yy);
}

static void scene_mat4_perspective_reverse_z_xy(float m[16], float h_half, float v_half, float near_z,
												float proj_x_offset, float proj_y_offset) {
	memset(m, 0, sizeof(float) * 16);
	m[0] = 1.0f / tanf(h_half);
	m[2] = proj_x_offset;
	/* Negated for the engine eye-y-down convention. */
	m[5] = -1.0f / tanf(v_half);
	m[6] = proj_y_offset;
	m[11] = near_z;
	m[14] = 1.0f;
}

/* Row-major view: rotate by the world->eye quat, translate by -R*pos. */
static void scene_mat4_view(float m[16], const float ori[4], const float pos[3]) {
	float r[9];
	scene_quat_to_mat3(ori, r);
	memset(m, 0, sizeof(float) * 16);
	for (int row = 0; row < 3; ++row) {
		m[row * 4 + 0] = r[row * 3 + 0];
		m[row * 4 + 1] = r[row * 3 + 1];
		m[row * 4 + 2] = r[row * 3 + 2];
		m[row * 4 + 3] = -(r[row * 3 + 0] * pos[0] + r[row * 3 + 1] * pos[1] + r[row * 3 + 2] * pos[2]);
	}
	m[15] = 1.0f;
}

static void scene_mat4_mul(float out[16], const float a[16], const float b[16]) {
	float t[16];
	for (int row = 0; row < 4; ++row)
		for (int col = 0; col < 4; ++col)
			t[row * 4 + col] = a[row * 4 + 0] * b[0 * 4 + col] + a[row * 4 + 1] * b[1 * 4 + col] +
							   a[row * 4 + 2] * b[2 * 4 + col] + a[row * 4 + 3] * b[3 * 4 + col];
	memcpy(out, t, sizeof t);
}

void AeronScene_ComputeViewProj(const AeronSceneCamera* camera, float out[16]) {
	if (!camera || !out) {
		return;
	}
	float proj[16];
	float view[16];
	scene_mat4_perspective_reverse_z_xy(proj, camera->h_half_rad, camera->v_half_rad,
										camera->near_z > 0.0f ? camera->near_z : 0.001f,
										camera->proj_x_offset, camera->proj_y_offset);
	scene_mat4_view(view, camera->ori, camera->pos);
	scene_mat4_mul(out, proj, view);
}
