require 'w2nn'

-- ref: http://arxiv.org/abs/1502.01852
-- ref: http://arxiv.org/abs/1501.00092
local srcnn = {}

function nn.SpatialConvolutionMM:reset(stdv)
   stdv = math.sqrt(2 / ((1.0 + 0.1 * 0.1) * self.kW * self.kH * self.nOutputPlane))
   self.weight:normal(0, stdv)
   self.bias:zero()
end
if cudnn and cudnn.SpatialConvolution then
   function cudnn.SpatialConvolution:reset(stdv)
      stdv = math.sqrt(2 / ((1.0 + 0.1 * 0.1) * self.kW * self.kH * self.nOutputPlane))
      self.weight:normal(0, stdv)
      self.bias:zero()
   end
end

function nn.SpatialConvolutionMM:clearState()
   if self.gradWeight then
      self.gradWeight = torch.Tensor(self.nOutputPlane, self.nInputPlane * self.kH * self.kW):typeAs(self.gradWeight):zero()
   end
   if self.gradBias then
      self.gradBias = torch.Tensor(self.nOutputPlane):typeAs(self.gradBias):zero()
   end
   return nn.utils.clear(self, 'finput', 'fgradInput', '_input', '_gradOutput', 'output', 'gradInput')
end

function srcnn.channels(model)
   return model:get(model:size() - 1).weight:size(1)
end
function srcnn.waifu2x_cunn(ch)
   local model = nn.Sequential()
   model:add(nn.SpatialConvolutionMM(ch, 32, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(nn.SpatialConvolutionMM(32, 32, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(nn.SpatialConvolutionMM(32, 64, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(nn.SpatialConvolutionMM(64, 64, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(nn.SpatialConvolutionMM(64, 128, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(nn.SpatialConvolutionMM(128, 128, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(nn.SpatialConvolutionMM(128, ch, 3, 3, 1, 1, 0, 0))
   model:add(nn.View(-1):setNumInputDims(3))
   --model:cuda()
   --print(model:forward(torch.Tensor(32, ch, 92, 92):uniform():cuda()):size())
   
   return model
end
function srcnn.waifu2x_cudnn(ch)
   local model = nn.Sequential()
   model:add(cudnn.SpatialConvolution(ch, 32, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(cudnn.SpatialConvolution(32, 32, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(cudnn.SpatialConvolution(32, 64, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(cudnn.SpatialConvolution(64, 64, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(cudnn.SpatialConvolution(64, 128, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(cudnn.SpatialConvolution(128, 128, 3, 3, 1, 1, 0, 0))
   model:add(w2nn.LeakyReLU(0.1))
   model:add(cudnn.SpatialConvolution(128, ch, 3, 3, 1, 1, 0, 0))
   model:add(nn.View(-1):setNumInputDims(3))
   --model:cuda()
   --print(model:forward(torch.Tensor(32, ch, 92, 92):uniform():cuda()):size())
   
   return model
end
function srcnn.create(model_name, backend, color)
   local ch = 3
   if color == "rgb" then
      ch = 3
   elseif color == "y" then
      ch = 1
   else
      error("unsupported color: " + color)
   end
   if backend == "cunn" then
      return srcnn.waifu2x_cunn(ch)
   elseif backend == "cudnn" then
      return srcnn.waifu2x_cudnn(ch)
   else
      error("unsupported backend: " +  backend)
   end
end
return srcnn
