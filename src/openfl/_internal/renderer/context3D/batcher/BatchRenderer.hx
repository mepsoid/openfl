package openfl._internal.renderer.context3D.batcher;

import haxe.ds.IntMap;
import lime.utils.Float32Array;
import lime.utils.UInt16Array;
import lime.graphics.WebGLRenderContext;
import openfl.display.BitmapData;
import openfl.display.BlendMode;
import openfl.display.Shader;
import openfl.display3D.IndexBuffer3D;
import openfl.display3D.VertexBuffer3D;
#if gl_stats
import openfl._internal.renderer.context3D.stats.Context3DStats;
import openfl._internal.renderer.context3D.stats.DrawCallContext;
#end

@:access(openfl.display.Shader)
@:access(openfl.display3D.Context3D)
@:access(openfl.display3D.VertexBuffer3D)
@SuppressWarnings("checkstyle:FieldDocComment")
class BatchRenderer
{
	private var gl:WebGLRenderContext;
	private var renderer:Context3DRenderer;

	private var __batch:Batch;

	private var __shader:BatchShader;
	private var __vertexBuffer:VertexBuffer3D;
	private var __indexBuffer:IndexBuffer3D;
	private var __buffer:Context3DBuffer;
	private var __maxQuads:Int;
	private var __maxTextures:Int;

	private static inline var MAX_TEXTURES:Int = 16;

	public function new(renderer:Context3DRenderer, maxQuads:Int)
	{
		this.renderer = renderer;
		this.gl = renderer.gl;

		var context = renderer.context3D;

		__maxQuads = maxQuads;
		__maxTextures = Std.int(Math.min(MAX_TEXTURES, gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS)));

		__shader = new BatchShader();
		__batch = new Batch(__maxQuads, __maxTextures);

		__vertexBuffer = context.createVertexBuffer(__maxQuads * 4, BatchShader.FLOATS_PER_VERTEX, DYNAMIC_DRAW);
		__vertexBuffer.uploadFromTypedArray(__batch.vertices);
		__indexBuffer = context.createIndexBuffer(__maxQuads * 6, STATIC_DRAW);
		__indexBuffer.uploadFromTypedArray(createIndicesForQuads(__maxQuads));
	}

	public function push(quad:Quad):Void
	{
		var terminateBatch:Bool = __batch.numQuads >= __maxQuads || renderer.__blendMode != quad.blendMode;
		if (terminateBatch)
		{
			flush();
		}
		var unit = 0;
		var texture:BitmapData = null;
		for (i in 0...__batch.numTextures)
		{
			if (__batch.textures[i] == quad.texture.bitmapData)
			{
				texture = __batch.textures[i];
				unit = i;
				break;
			}
		}
		if (texture == null)
		{
			if (__batch.numTextures == __maxTextures)
			{
				flush();
			}
			texture = quad.texture.bitmapData;
			unit = __batch.numTextures;
			__batch.textures[__batch.numTextures++] = texture;
		}
		__batch.push(unit, quad);
	}

	public function flush():Void
	{
		if (__batch.numQuads == 0)
		{
			return;
		}

		var context = renderer.context3D;

		renderer.__setBlendMode(renderer.__blendMode);

		context.__bindGLArrayBuffer(__vertexBuffer.__id);

		var subArray = __batch.vertices.subarray(0, __batch.numQuads * Batch.FLOATS_PER_QUAD);
		gl.bufferSubData(gl.ARRAY_BUFFER, 0, subArray);

		renderer.setShader(__shader);
		// TODO:
		// for (i in 0...batch.numTextures)
		// {
		__shader.uSampler.input = __batch.textures[0];
		// }
		renderer.updateShader();

		context.setVertexBufferAt(__shader.__position.index, __vertexBuffer, 0, FLOAT_2);
		context.setVertexBufferAt(__shader.__textureCoord.index, __vertexBuffer, 2, FLOAT_2);
		context.setVertexBufferAt(__shader.__colorMultiplier.index, __vertexBuffer, 4, FLOAT_4);
		context.setVertexBufferAt(__shader.__colorOffset.index, __vertexBuffer, 8, FLOAT_4);
		context.setVertexBufferAt(__shader.aTextureId.index, __vertexBuffer, 12, FLOAT_1);

		context.drawTriangles(__indexBuffer, 0, __batch.numQuads * 2);

		#if gl_stats
		Context3DStats.incrementDrawCall(DrawCallContext.STAGE);
		#end

		renderer.__clearShader();
		context.__flushGL();
		// start new batch
		__batch.clear();
	}

	private static function createIndicesForQuads(numQuads:Int):UInt16Array
	{
		var totalIndices = numQuads * 6; // 2 triangles of 3 verties per quad
		var indices = new UInt16Array(totalIndices);
		var i = 0, j = 0;
		while (i < totalIndices)
		{
			indices[i + 0] = j + 0;
			indices[i + 1] = j + 1;
			indices[i + 2] = j + 2;
			indices[i + 3] = j + 0;
			indices[i + 4] = j + 2;
			indices[i + 5] = j + 3;
			i += 6;
			j += 4;
		}
		return indices;
	}
}

private class Batch
{
	public var indices:UInt16Array;
	public var vertices:Float32Array;
	public var textures:Array<BitmapData>;

	public var numQuads:Int = 0;
	public var numTextures:Int = 0;

	public static inline var FLOATS_PER_QUAD = BatchShader.FLOATS_PER_VERTEX * 4;

	public function new(maxQuads:Int, maxTextures:Int)
	{
		vertices = new Float32Array(maxQuads * FLOATS_PER_QUAD);
		indices = new UInt16Array(maxQuads * 6);
		textures = [for (i in 0...maxTextures) null];
	}

	public function clear()
	{
		numQuads = 0;
		numTextures = 0;
	}

	public function push(textureUnit:Int, quad:Quad)
	{
		var vertexData = quad.vertexData;
		var uvs = quad.texture.uvs;
		var alpha = quad.alpha;
		var colorTransform = quad.colorTransform;
		var currentVertexBufferIndex = numQuads * FLOATS_PER_QUAD;

		inline function setVertex(i):Void
		{
			var offset = currentVertexBufferIndex + i * BatchShader.FLOATS_PER_VERTEX;
			vertices[offset + 0] = vertexData[i * 2 + 0];
			vertices[offset + 1] = vertexData[i * 2 + 1];

			vertices[offset + 2] = uvs[i * 2 + 0];
			vertices[offset + 3] = uvs[i * 2 + 1];

			if (colorTransform != null)
			{
				vertices[offset + 4] = colorTransform.redOffset / 255;
				vertices[offset + 5] = colorTransform.greenOffset / 255;
				vertices[offset + 6] = colorTransform.blueOffset / 255;
				vertices[offset + 7] = (colorTransform.alphaOffset / 255) * alpha;

				vertices[offset + 8] = colorTransform.redMultiplier;
				vertices[offset + 9] = colorTransform.greenMultiplier;
				vertices[offset + 10] = colorTransform.blueMultiplier;
				vertices[offset + 11] = colorTransform.alphaMultiplier * alpha;
			}
			else
			{
				vertices[offset + 4] = 0;
				vertices[offset + 5] = 0;
				vertices[offset + 6] = 0;
				vertices[offset + 7] = 0;

				vertices[offset + 8] = 1;
				vertices[offset + 9] = 1;
				vertices[offset + 10] = 1;
				vertices[offset + 11] = alpha;
			}
			vertices[offset + 12] = textureUnit;
		}

		setVertex(0);
		setVertex(1);
		setVertex(2);
		setVertex(3);

		++numQuads;
	}
}

private class BatchShader extends Shader
{
	public static inline var FLOATS_PER_VERTEX = 2 + 2 + 4 + 4 + 1;

	@:glVertexSource("
		attribute vec4 openfl_ColorMultiplier;
		attribute vec4 openfl_ColorOffset;
		attribute vec2 openfl_Position;
		attribute vec2 openfl_TextureCoord;
		attribute float aTextureId;

		uniform mat4 openfl_Matrix;

		varying vec4 openfl_ColorMultiplierv;
		varying vec4 openfl_ColorOffsetv;
		varying vec2 openfl_TextureCoordv;
		varying float vTextureId;

		void main(void) {
			gl_Position = openfl_Matrix * vec4(openfl_Position, 0, 1);
			openfl_TextureCoordv = openfl_TextureCoord;
			openfl_ColorMultiplierv = openfl_ColorMultiplier;
			openfl_ColorOffsetv = openfl_ColorOffset;
			vTextureId = aTextureId;
		}
	")
	@:glFragmentSource('
		varying vec4 openfl_ColorMultiplierv;
		varying vec4 openfl_ColorOffsetv;
		varying vec2 openfl_TextureCoordv;
		varying float vTextureId;

		uniform sampler2D uSampler;

		void main(void) {
			vec4 color = texture2D(uSampler, openfl_TextureCoordv);
			if (color.a == 0.0) {

				gl_FragColor = vec4 (0.0, 0.0, 0.0, 0.0);

			} else {

				color = vec4 (color.rgb / color.a, color.a);

				mat4 colorMultiplier = mat4 (0);
				colorMultiplier[0][0] = openfl_ColorMultiplierv.x;
				colorMultiplier[1][1] = openfl_ColorMultiplierv.y;
				colorMultiplier[2][2] = openfl_ColorMultiplierv.z;
				colorMultiplier[3][3] = 1.0; // openfl_ColorMultiplierv.w;

				color = clamp (openfl_ColorOffsetv + (color * colorMultiplier), 0.0, 1.0);

				if (color.a > 0.0) {

					gl_FragColor = vec4 (color.rgb * color.a, color.a);

				} else {

					gl_FragColor = vec4 (0.0, 0.0, 0.0, 0.0);

				}
			}
		}
	')
	public function new()
	{
		super();
	}
}
