require 'xlua'
require 'pl'
require 'trepl'

-- global settings

if package.preload.settings then
   return package.preload.settings
end

-- default tensor type
torch.setdefaulttensortype('torch.FloatTensor')

local settings = {}

local cmd = torch.CmdLine()
cmd:text()
cmd:text("waifu2x-training")
cmd:text("Options:")
cmd:option("-gpu", -1, 'GPU Device ID')
cmd:option("-seed", 11, 'RNG seed')
cmd:option("-data_dir", "./data", 'path to data directory')
cmd:option("-backend", "cunn", '(cunn|cudnn)')
cmd:option("-test", "images/miku_small.png", 'path to test image')
cmd:option("-model_dir", "./models", 'model directory')
cmd:option("-method", "scale", 'method to training (noise|scale)')
cmd:option("-noise_level", 1, '(1|2|3)')
cmd:option("-style", "art", '(art|photo)')
cmd:option("-color", 'rgb', '(y|rgb)')
cmd:option("-random_color_noise_rate", 0.0, 'data augmentation using color noise (0.0-1.0)')
cmd:option("-random_overlay_rate", 0.0, 'data augmentation using flipped image overlay (0.0-1.0)')
cmd:option("-random_half_rate", 0.0, 'data augmentation using half resolution image (0.0-1.0)')
cmd:option("-random_unsharp_mask_rate", 0.0, 'data augmentation using unsharp mask (0.0-1.0)')
cmd:option("-scale", 2.0, 'scale factor (2)')
cmd:option("-learning_rate", 0.0005, 'learning rate for adam')
cmd:option("-crop_size", 46, 'crop size')
cmd:option("-max_size", 256, 'if image is larger than max_size, image will be crop to max_size randomly')
cmd:option("-batch_size", 8, 'mini batch size')
cmd:option("-patches", 16, 'number of patch samples')
cmd:option("-inner_epoch", 4, 'number of inner epochs')
cmd:option("-epoch", 30, 'number of epochs to run')
cmd:option("-thread", -1, 'number of CPU threads')
cmd:option("-jpeg_chroma_subsampling_rate", 0.0, 'the rate of YUV 4:2:0/YUV 4:4:4 in denoising training (0.0-1.0)')
cmd:option("-validation_rate", 0.05, 'validation-set rate (number_of_training_images * validation_rate > 1)')
cmd:option("-validation_crops", 160, 'number of cropping region per image in validation')
cmd:option("-active_cropping_rate", 0.5, 'active cropping rate')
cmd:option("-active_cropping_tries", 10, 'active cropping tries')
cmd:option("-nr_rate", 0.75, 'trade-off between reducing noise and erasing details (0.0-1.0)')
cmd:option("-save_history", 0, 'save all model (0|1)')
cmd:option("-plot", 0, 'plot loss chart(0|1)')
cmd:option("-downsampling_filters", "Box,Catrom", '(comma separated)downsampling filters for 2x scale training. (Point,Box,Triangle,Hermite,Hanning,Hamming,Blackman,Gaussian,Quadratic,Cubic,Catrom,Mitchell,Lanczos,Bessel,Sinc)')

local opt = cmd:parse(arg)
for k, v in pairs(opt) do
   settings[k] = v
end
if settings.plot == 1 then
   settings.plot = true
   require 'gnuplot'
else
   settings.plot = false
end
if settings.save_history == 1 then
   settings.save_history = true
else
   settings.save_history = false
end
if settings.save_history then
   if settings.method == "noise" then
      settings.model_file = string.format("%s/noise%d_model.%%d-%%d.t7",
					  settings.model_dir, settings.noise_level)
   elseif settings.method == "scale" then
      settings.model_file = string.format("%s/scale%.1fx_model.%%d-%%d.t7",
					  settings.model_dir, settings.scale)
   else
      error("unknown method: " .. settings.method)
   end
else
   if settings.method == "noise" then
      settings.model_file = string.format("%s/noise%d_model.t7",
					  settings.model_dir, settings.noise_level)
   elseif settings.method == "scale" then
      settings.model_file = string.format("%s/scale%.1fx_model.t7",
					  settings.model_dir, settings.scale)
   else
      error("unknown method: " .. settings.method)
   end
end
if not (settings.color == "rgb" or settings.color == "y") then
   error("color must be y or rgb")
end
if not (settings.scale == math.floor(settings.scale) and settings.scale % 2 == 0) then
   error("scale must be mod-2")
end
if not (settings.style == "art" or
	settings.style == "photo") then
   error(string.format("unknown style: %s", settings.style))
end
if settings.thread > 0 then
   torch.setnumthreads(tonumber(settings.thread))
end
if settings.downsampling_filters and settings.downsampling_filters:len() > 0 then
   settings.downsampling_filters = settings.downsampling_filters:split(",")
else
   settings.downsampling_filters = {"Box", "Lanczos", "Catrom"}
end

settings.images = string.format("%s/images.t7", settings.data_dir)
settings.image_list = string.format("%s/image_list.txt", settings.data_dir)

return settings
