require 'pl'
local __FILE__ = (function() return string.gsub(debug.getinfo(2, 'S').source, "^@", "") end)()
local ROOT = path.dirname(__FILE__)
package.path = path.join(ROOT, "lib", "?.lua;") .. package.path
_G.TURBO_SSL = true

require 'w2nn'
local uuid = require 'uuid'
local ffi = require 'ffi'
local md5 = require 'md5'
local iproc = require 'iproc'
local reconstruct = require 'reconstruct'
local image_loader = require 'image_loader'
local alpha_util = require 'alpha_util'
local gm = require 'graphicsmagick'

-- Note:  turbo and xlua has different implementation of string:split().
--         Therefore, string:split() has conflict issue.
--         In this script, use turbo's string:split().
local turbo = require 'turbo'

local cmd = torch.CmdLine()
cmd:text()
cmd:text("waifu2x-api")
cmd:text("Options:")
cmd:option("-port", 8812, 'listen port')
cmd:option("-gpu", 1, 'Device ID')
cmd:option("-thread", -1, 'number of CPU threads')
local opt = cmd:parse(arg)
cutorch.setDevice(opt.gpu)
torch.setdefaulttensortype('torch.FloatTensor')
if opt.thread > 0 then
   torch.setnumthreads(opt.thread)
end
if cudnn then
   cudnn.fastest = true
   cudnn.benchmark = false
end
local ART_MODEL_DIR = path.join(ROOT, "models", "anime_style_art_rgb")
local PHOTO_MODEL_DIR = path.join(ROOT, "models", "photo")
local art_scale2_model = torch.load(path.join(ART_MODEL_DIR, "scale2.0x_model.t7"), "ascii")
local art_noise1_model = torch.load(path.join(ART_MODEL_DIR, "noise1_model.t7"), "ascii")
local art_noise2_model = torch.load(path.join(ART_MODEL_DIR, "noise2_model.t7"), "ascii")
local art_noise3_model = torch.load(path.join(ART_MODEL_DIR, "noise3_model.t7"), "ascii")
local photo_scale2_model = torch.load(path.join(PHOTO_MODEL_DIR, "scale2.0x_model.t7"), "ascii")
local photo_noise1_model = torch.load(path.join(PHOTO_MODEL_DIR, "noise1_model.t7"), "ascii")
local photo_noise2_model = torch.load(path.join(PHOTO_MODEL_DIR, "noise2_model.t7"), "ascii")
local photo_noise3_model = torch.load(path.join(PHOTO_MODEL_DIR, "noise3_model.t7"), "ascii")
local CLEANUP_MODEL = false -- if you are using the low memory GPU, you could use this flag.
local CACHE_DIR = path.join(ROOT, "cache")
local MAX_NOISE_IMAGE = 2560 * 2560
local MAX_SCALE_IMAGE = 1280 * 1280
local CURL_OPTIONS = {
   request_timeout = 60,
   connect_timeout = 60,
   allow_redirects = true,
   max_redirects = 2
}
local CURL_MAX_SIZE = 3 * 1024 * 1024

local function valid_size(x, scale)
   if scale == 0 then
      return x:size(2) * x:size(3) <= MAX_NOISE_IMAGE
   else
      return x:size(2) * x:size(3) <= MAX_SCALE_IMAGE
   end
end

local function cache_url(url)
   local hash = md5.sumhexa(url)
   local cache_file = path.join(CACHE_DIR, "url_" .. hash)
   if path.exists(cache_file) then
      return image_loader.load_float(cache_file)
   else
      local res = coroutine.yield(
	 turbo.async.HTTPClient({verify_ca=false},
	    nil,
	    CURL_MAX_SIZE):fetch(url, CURL_OPTIONS)
      )
      if res.code == 200 then
	 local content_type = res.headers:get("Content-Type", true)
	 if type(content_type) == "table" then
	    content_type = content_type[1]
	 end
	 if content_type and content_type:find("image") then
	    local fp = io.open(cache_file, "wb")
	    local blob = res.body
	    fp:write(blob)
	    fp:close()
	    return image_loader.decode_float(blob)
	 end
      end
   end
   return nil, nil, nil
end
local function get_image(req)
   local file_info = req:get_arguments("file")
   local url = req:get_argument("url", "")
   local file = nil
   local filename = nil
   if file_info and #file_info == 1 then
      file = file_info[1][1]
      local disp = file_info[1]["content-disposition"]
      if disp and disp["filename"] then
	 filename = path.basename(disp["filename"])
      end
   end
   if file and file:len() > 0 then
      local x, alpha, blob = image_loader.decode_float(file)
      return x, alpha, blob, filename
   elseif url and url:len() > 0 then
      local x, alpha, blob = cache_url(url)
      return x, alpha, blob, filename
   end
   return nil, nil, nil, nil
end
local function cleanup_model(model)
   if CLEANUP_MODEL then
      model:clearState() -- release GPU memory
   end
end
local function convert(x, alpha, options)
   local cache_file = path.join(CACHE_DIR, options.prefix .. ".png")
   local alpha_cache_file = path.join(CACHE_DIR, options.alpha_prefix .. ".png")
   local alpha_orig = alpha

   if path.exists(alpha_cache_file) then
      alpha = image_loader.load_float(alpha_cache_file)
      if alpha:dim() == 2 then
	 alpha = alpha:reshape(1, alpha:size(1), alpha:size(2))
      end
      if alpha:size(1) == 3 then
	 alpha = image.rgb2y(alpha)
      end
   end
   if path.exists(cache_file) then
      x = image_loader.load_float(cache_file)
      return x, alpha
   else
      if options.style == "art" then
	 if options.border then
	    x = alpha_util.make_border(x, alpha_orig, reconstruct.offset_size(art_scale2_model))
	 end
	 if options.method == "scale" then
	    x = reconstruct.scale(art_scale2_model, 2.0, x)
	    if alpha then
	       if not (alpha:size(2) == x:size(2) and alpha:size(3) == x:size(3)) then
		  alpha = reconstruct.scale(art_scale2_model, 2.0, alpha)
		  image_loader.save_png(alpha_cache_file, alpha)
	       end
	    end
	    cleanup_model(art_scale2_model)
	 elseif options.method == "noise1" then
	    x = reconstruct.image(art_noise1_model, x)
	    cleanup_model(art_noise1_model)
	 elseif options.method == "noise2" then
	    x = reconstruct.image(art_noise2_model, x)
	    cleanup_model(art_noise2_model)
	 elseif options.method == "noise3" then
	    x = reconstruct.image(art_noise3_model, x)
	    cleanup_model(art_noise3_model)
	 end
      else -- photo
	 if options.border then
	    x = alpha_util.make_border(x, alpha, reconstruct.offset_size(photo_scale2_model))
	 end
	 if options.method == "scale" then
	    x = reconstruct.scale(photo_scale2_model, 2.0, x)
	    if alpha then
	       if not (alpha:size(2) == x:size(2) and alpha:size(3) == x:size(3)) then
		  alpha = reconstruct.scale(photo_scale2_model, 2.0, alpha)
		  image_loader.save_png(alpha_cache_file, alpha)
	       end
	    end
	    cleanup_model(photo_scale2_model)
	 elseif options.method == "noise1" then
	    x = reconstruct.image(photo_noise1_model, x)
	    cleanup_model(photo_noise1_model)
	 elseif options.method == "noise2" then
	    x = reconstruct.image(photo_noise2_model, x)
	    cleanup_model(photo_noise2_model)
	 elseif options.method == "noise3" then
	    x = reconstruct.image(photo_noise3_model, x)
	    cleanup_model(photo_noise3_model)
	 end
      end
      image_loader.save_png(cache_file, x)

      return x, alpha
   end
end
local function client_disconnected(handler)
   return not(handler.request and
		 handler.request.connection and
		 handler.request.connection.stream and
		 (not handler.request.connection.stream:closed()))
end
local function make_output_filename(filename, mode)
   local e = path.extension(filename)
   local base = filename:sub(0, filename:len() - e:len())
   if mode then
      return base .. "_waifu2x_" .. mode .. ".png"
   else
      return base .. ".png"
   end
end

local APIHandler = class("APIHandler", turbo.web.RequestHandler)
function APIHandler:post()
   if client_disconnected(self) then
      self:set_status(400)
      self:write("client disconnected")
      return
   end
   local x, alpha, blob, filename = get_image(self)
   local scale = tonumber(self:get_argument("scale", "0"))
   local noise = tonumber(self:get_argument("noise", "0"))
   local style = self:get_argument("style", "art")
   local download = (self:get_argument("download", "")):len()

   if style ~= "art" then
      style = "photo" -- style must be art or photo
   end
   if x and valid_size(x, scale) then
      local prefix = nil
      if (noise ~= 0 or scale ~= 0) then
	 local hash = md5.sumhexa(blob)
	 local alpha_prefix = style .. "_" .. hash .. "_alpha"
	 local border = false
	 if scale ~= 0 and alpha then
	    border = true
	 end
	 if noise == 1 then
	    prefix = style .. "_noise1_"
	    x = convert(x, alpha, {method = "noise1", style = style,
				   prefix = prefix .. hash,
				   alpha_prefix = alpha_prefix, border = border})
	    border = false
	 elseif noise == 2 then
	    prefix = style .. "_noise2_"
	    x = convert(x, alpha, {method = "noise2", style = style,
				   prefix = prefix .. hash, 
				   alpha_prefix = alpha_prefix, border = border})
	    border = false
	 elseif noise == 3 then
	    prefix = style .. "_noise3_"
	    x = convert(x, alpha, {method = "noise3", style = style,
				   prefix = prefix .. hash, 
				   alpha_prefix = alpha_prefix, border = border})
	    border = false
	 end
	 if scale == 1 or scale == 2 then
	    if noise == 1 then
	       prefix = style .. "_noise1_scale_"
	    elseif noise == 2 then
	       prefix = style .. "_noise2_scale_"
	    elseif noise == 3 then
	       prefix = style .. "_noise3_scale_"
	    else
	       prefix = style .. "_scale_"
	    end
	    x, alpha = convert(x, alpha, {method = "scale", style = style, prefix = prefix .. hash, alpha_prefix = alpha_prefix, border = border})
	    if scale == 1 then
	       x = iproc.scale(x, x:size(3) * (1.6 / 2.0), x:size(2) * (1.6 / 2.0), "Sinc")
	    end
	 end
      end
      local name = nil
      if filename then 
	 if prefix then
	    name = make_output_filename(filename, prefix:sub(0, prefix:len()-1))
	 else
	    name = make_output_filename(filename, nil)
	 end
      else
	 name = uuid() .. ".png"
      end
      local blob = image_loader.encode_png(alpha_util.composite(x, alpha), 8, true)

      self:set_header("Content-Length", string.format("%d", #blob))
      if download > 0 then
	 self:set_header("Content-Type", "application/octet-stream")
	 self:set_header("Content-Disposition", string.format('attachment; filename="%s"', name))
      else
	 self:set_header("Content-Type", "image/png")
	 self:set_header("Content-Disposition", string.format('inline; filename="%s"', name))
      end
      self:write(blob)
   else
      if not x then
	 self:set_status(400)
	 self:write("ERROR: An error occurred. (unsupported image format/connection timeout/file is too large)")
      else
	 self:set_status(400)
	 self:write("ERROR: image size exceeds maximum allowable size.")
      end
   end
   collectgarbage()
end
local FormHandler = class("FormHandler", turbo.web.RequestHandler)
local index_ja = file.read(path.join(ROOT, "assets", "index.ja.html"))
local index_ru = file.read(path.join(ROOT, "assets", "index.ru.html"))
local index_pt = file.read(path.join(ROOT, "assets", "index.pt.html"))
local index_es = file.read(path.join(ROOT, "assets", "index.es.html"))
local index_fr = file.read(path.join(ROOT, "assets", "index.fr.html"))
local index_de = file.read(path.join(ROOT, "assets", "index.de.html"))
local index_tr = file.read(path.join(ROOT, "assets", "index.tr.html"))
local index_zh_cn = file.read(path.join(ROOT, "assets", "index.zh-CN.html"))
local index_en = file.read(path.join(ROOT, "assets", "index.html"))
function FormHandler:get()
   local lang = self.request.headers:get("Accept-Language")
   if lang then
      local langs = utils.split(lang, ",")
      for i = 1, #langs do
	 langs[i] = utils.split(langs[i], ";")[1]
      end
      if langs[1] == "ja" then
	 self:write(index_ja)
      elseif langs[1] == "ru" then
	 self:write(index_ru)
      elseif langs[1] == "pt" or langs[1] == "pt-BR" then
	 self:write(index_pt)
      elseif langs[1] == "es" or langs[1] == "es-ES" then
	 self:write(index_es)
      elseif langs[1] == "fr" then
	 self:write(index_fr)
      elseif langs[1] == "de" then
	 self:write(index_de)
      elseif langs[1] == "tr" then
	 self:write(index_tr)
      elseif langs[1] == "zh-CN" or langs[1] == "zh" then
	 self:write(index_zh_cn)
      else
	 self:write(index_en)
      end
   else
      self:write(index_en)
   end
end
turbo.log.categories = {
   ["success"] = true,
   ["notice"] = false,
   ["warning"] = true,
   ["error"] = true,
   ["debug"] = false,
   ["development"] = false
}
local app = turbo.web.Application:new(
   {
      {"^/$", FormHandler},
      {"^/api$", APIHandler},
      {"^/([%a%d%.%-_]+)$", turbo.web.StaticFileHandler, path.join(ROOT, "assets/")},
   }
)
app:listen(opt.port, "0.0.0.0", {max_body_size = CURL_MAX_SIZE})
turbo.ioloop.instance():start()
