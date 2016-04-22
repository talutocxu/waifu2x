require 'pl'
local __FILE__ = (function() return string.gsub(debug.getinfo(2, 'S').source, "^@", "") end)()
package.path = path.join(path.dirname(__FILE__), "lib", "?.lua;") .. package.path
require 'sys'
require 'w2nn'
local iproc = require 'iproc'
local reconstruct = require 'reconstruct'
local image_loader = require 'image_loader'
local alpha_util = require 'alpha_util'

torch.setdefaulttensortype('torch.FloatTensor')

local function convert_image(opt)
   local x, alpha = image_loader.load_float(opt.i)
   local new_x = nil
   local t = sys.clock()
   local scale_f, image_f

   if opt.tta == 1 then
      scale_f = reconstruct.scale_tta
      image_f = reconstruct.image_tta
   else
      scale_f = reconstruct.scale
      image_f = reconstruct.image
   end
   if opt.o == "(auto)" then
      local name = path.basename(opt.i)
      local e = path.extension(name)
      local base = name:sub(0, name:len() - e:len())
      opt.o = path.join(path.dirname(opt.i), string.format("%s_%s.png", base, opt.m))
   end
   if opt.m == "noise" then
      local model_path = path.join(opt.model_dir, ("noise%d_model.t7"):format(opt.noise_level))
      local model = torch.load(model_path, "ascii")
      if not model then
	 error("Load Error: " .. model_path)
      end
      new_x = image_f(model, x, opt.crop_size)
      new_x = alpha_util.composite(new_x, alpha)
   elseif opt.m == "scale" then
      local model_path = path.join(opt.model_dir, ("scale%.1fx_model.t7"):format(opt.scale))
      local model = torch.load(model_path, "ascii")
      if not model then
	 error("Load Error: " .. model_path)
      end
      x = alpha_util.make_border(x, alpha, reconstruct.offset_size(model))
      new_x = scale_f(model, opt.scale, x, opt.crop_size)
      new_x = alpha_util.composite(new_x, alpha, model)
   elseif opt.m == "noise_scale" then
      local noise_model_path = path.join(opt.model_dir, ("noise%d_model.t7"):format(opt.noise_level))
      local noise_model = torch.load(noise_model_path, "ascii")
      local scale_model_path = path.join(opt.model_dir, ("scale%.1fx_model.t7"):format(opt.scale))
      local scale_model = torch.load(scale_model_path, "ascii")
      
      if not noise_model then
	 error("Load Error: " .. noise_model_path)
      end
      if not scale_model then
	 error("Load Error: " .. scale_model_path)
      end
      x = alpha_util.make_border(x, alpha, reconstruct.offset_size(scale_model))
      x = image_f(noise_model, x, opt.crop_size)
      new_x = scale_f(scale_model, opt.scale, x, opt.crop_size)
      new_x = alpha_util.composite(new_x, alpha, scale_model)
   else
      error("undefined method:" .. opt.method)
   end
   image_loader.save_png(opt.o, new_x, opt.depth, true)
   print(opt.o .. ": " .. (sys.clock() - t) .. " sec")
end
local function convert_frames(opt)
   local model_path, scale_model
   local noise_model = {}
   local scale_f, image_f
   if opt.tta == 1 then
      scale_f = reconstruct.scale_tta
      image_f = reconstruct.image_tta
   else
      scale_f = reconstruct.scale
      image_f = reconstruct.image
   end
   if opt.m == "scale" then
      model_path = path.join(opt.model_dir, ("scale%.1fx_model.t7"):format(opt.scale))
      scale_model = torch.load(model_path, "ascii")
      if not scale_model then
	 error("Load Error: " .. model_path)
      end
   elseif opt.m == "noise" then
      model_path = path.join(opt.model_dir, string.format("noise%d_model.t7", opt.noise_level))
      noise_model[opt.noise_level] = torch.load(model_path, "ascii")
      if not noise_model[opt.noise_level] then
	 error("Load Error: " .. model_path)
      end
   elseif opt.m == "noise_scale" then
      model_path = path.join(opt.model_dir, ("scale%.1fx_model.t7"):format(opt.scale))
      scale_model = torch.load(model_path, "ascii")
      if not scale_model then
	 error("Load Error: " .. model_path)
      end
      model_path = path.join(opt.model_dir, string.format("noise%d_model.t7", opt.noise_level))
      noise_model[opt.noise_level] = torch.load(model_path, "ascii")
      if not noise_model[opt.noise_level] then
	 error("Load Error: " .. model_path)
      end
   end
   local fp = io.open(opt.l)
   if not fp then
      error("Open Error: " .. opt.l)
   end
   local count = 0
   local lines = {}
   for line in fp:lines() do
      table.insert(lines, line)
   end
   fp:close()
   for i = 1, #lines do
      if opt.resume == 0 or path.exists(string.format(opt.o, i)) == false then
	 local x, alpha = image_loader.load_float(lines[i])
	 local new_x = nil
	 if opt.m == "noise" then
	    new_x = image_f(noise_model[opt.noise_level], x, opt.crop_size)
	    new_x = alpha_util.composite(new_x, alpha)
	 elseif opt.m == "scale" then
	    x = alpha_util.make_border(x, alpha, reconstruct.offset_size(scale_model))
	    new_x = scale_f(scale_model, opt.scale, x, opt.crop_size)
	    new_x = alpha_util.composite(new_x, alpha, scale_model)
	 elseif opt.m == "noise_scale" then
	    x = alpha_util.make_border(x, alpha, reconstruct.offset_size(scale_model))
	    x = image_f(noise_model[opt.noise_level], x, opt.crop_size)
	    new_x = scale_f(scale_model, opt.scale, x, opt.crop_size)
	    new_x = alpha_util.composite(new_x, alpha, scale_model)
	 else
	    error("undefined method:" .. opt.method)
	 end
	 local output = nil
	 if opt.o == "(auto)" then
	    local name = path.basename(lines[i])
	    local e = path.extension(name)
	    local base = name:sub(0, name:len() - e:len())
	    output = path.join(path.dirname(opt.i), string.format("%s(%s).png", base, opt.m))
	 else
	    output = string.format(opt.o, i)
	 end
	 image_loader.save_png(output, new_x, opt.depth, true)
	 xlua.progress(i, #lines)
	 if i % 10 == 0 then
	    collectgarbage()
	 end
      else
	 xlua.progress(i, #lines)
      end
   end
end

local function waifu2x()
   local cmd = torch.CmdLine()
   cmd:text()
   cmd:text("waifu2x")
   cmd:text("Options:")
   cmd:option("-i", "images/miku_small.png", 'path to input image')
   cmd:option("-l", "", 'path to image-list.txt')
   cmd:option("-scale", 2, 'scale factor')
   cmd:option("-o", "(auto)", 'path to output file')
   cmd:option("-depth", 8, 'bit-depth of the output image (8|16)')
   cmd:option("-model_dir", "./models/anime_style_art_rgb", 'path to model directory')
   cmd:option("-m", "noise_scale", 'method (noise|scale|noise_scale)')
   cmd:option("-noise_level", 1, '(1|2|3)')
   cmd:option("-crop_size", 128, 'patch size per process')
   cmd:option("-resume", 0, "skip existing files (0|1)")
   cmd:option("-thread", -1, "number of CPU threads")
   cmd:option("-tta", 0, '8x slower and slightly high quality (0|1)')
   
   local opt = cmd:parse(arg)
   if opt.thread > 0 then
      torch.setnumthreads(opt.thread)
   end
   if cudnn then
      cudnn.fastest = true
      cudnn.benchmark = false
   end
   
   if string.len(opt.l) == 0 then
      convert_image(opt)
   else
      convert_frames(opt)
   end
end
waifu2x()
