require 'rnn'
require 'cutorch'
require 'cunn'
require 'cudnn'
require 'optim'
require 'data_loader'
require 'paths'
require 'gnuplot'

--[[command line arguments]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a dataset using LSTM')
cmd:text('Example:')
cmd:text("LSTM.lua --rho 10")
cmd:text('Options:')
cmd:option('--trainPath', '', 'train.h5 path')
cmd:option('--valPath', '', 'validation.h5 path')
cmd:option('--learningRate', 0.01, 'learning rate at t=0')
cmd:option('--momentum', 0.9, 'momentum')
cmd:option('--batchSize', 32, 'number of examples per batch')
--cmd:option('--cuda', false, 'use CUDA')
--cmd:option('--useDevice', 1, 'sets the device (GPU) to use')
cmd:option('--maxEpoch', 1000, 'maximum number of epochs to run')
--cmd:option('--maxTries', 50, 'maximum number of epochs to try to find a better local minima for early-stopping')
cmd:option('--uniform', 0.1, 'initialize parameters using uniform distribution between -uniform and uniform. -1 means default initialization')

-- recurrent layer
cmd:option('--rho', 5, 'back-propagate through time (BPTT) for rho time-steps')
cmd:option('--hiddenSize', 200, 'number of hidden units used at output of each recurrent layer. When more than one is specified, RNN/LSTMs/GRUs are stacked')
cmd:option('--depth', 1, 'number of hidden layers')
--cmd:option('--zeroFirst', false, 'first step will forward zero through recurrence (i.e. add bias of recurrence). As opposed to learning bias specifically for first step.')
cmd:option('--dropoutProb', 0.5, 'probability of zeroing a neuron (dropout probability)')

-- other
cmd:option('--printEvery', 0, 'print loss every n iters')
cmd:option('--testEvery', 1, 'print test accuracy every n epochs')
cmd:option('--logPath', './log.txt', 'log here')
cmd:option('--savePath', './snapshots', 'save snapshots here')
cmd:option('--saveEvery', 0, 'number of epochs to save model snapshot')
cmd:option('--plotRegression', 0, 'number of epochs to plot regression approximation')

cmd:text()
opt = cmd:parse(arg or {})

-- snapshots folder
if opt.saveEvery ~= 0 then
  paths.mkdir(paths.concat(opt.savePath, os.date("%d_%m_%y-%T")))
end
-- initialize dataset
local trainDB = SequentialDB(opt.trainPath, opt.batchSize, opt.rho)
local valDB = SequentialDB(opt.valPath, 1, opt.rho) --bs=1 to loop only once through all the data.
valDB.batchIndexs = torch.linspace(1,opt.batchSize, opt.batchSize)
local dataDim = trainDB.dim[2]*trainDB.dim[3]*trainDB.dim[4] -- get flat data dimensions
-- start logger
logger = optim.Logger(opt.logPath)
logger:setNames{'epoch', 'train error', 'test error'}

-- turn on recurrent batchnorm
nn.FastLSTM.bn = true
-- build LSTM RNN
local rnn = nn.Sequential()
rnn:add(nn.SplitTable(1,2)) -- (bs, rho, dim)
rnn = rnn:add(nn.Sequencer(nn.FastLSTM(dataDim, opt.hiddenSize)))
if opt.dropoutProb > 0 then
  rnn = rnn:add(nn.Sequencer(nn.Dropout(opt.dropoutProb)))
end

for d = 1,(opt.depth - 1) do
  rnn = rnn:add(nn.Sequencer(nn.FastLSTM(opt.hiddenSize, opt.hiddenSize)))
  if opt.dropoutProb > 0 then
    rnn = rnn:add(nn.Sequencer(nn.Dropout(opt.dropoutProb)))
  end
end
rnn = rnn:add(nn.Sequencer(nn.Linear(opt.hiddenSize, trainDB.ldim[2])))
rnn:add(nn.SelectTable(-1))

-- CPU -> GPU
rnn:cuda()

-- random init weights
for k,param in ipairs(rnn:parameters()) do
  param:uniform(-opt.uniform, opt.uniform)
end

-- show the network
print(rnn)

-- build criterion
local criterion = nn.MSECriterion():cuda()

-- optimizer state
local optimState = {learningRate = opt.learningRate}

parameters, gradParameters = rnn:getParameters()

-- save only the necessary values
lightModel = rnn:clone('weight','bias','running_mean','running_std')

--set current epoch
local epoch = 1

function train()
  rnn:training()

  local feval = function(x)
    if x ~= parameters then parameters:copy(x) end
    gradParameters:zero()
    inputs, targets = trainDB:getBatch()
    inputs = inputs:resize(opt.batchSize,opt.rho,dataDim):cuda()
    targets = targets[{{},-1,{}}]:resize(opt.batchSize, valDB.ldim[2]):cuda()
    outputs = rnn:forward(inputs)
    local f = criterion:forward(outputs, targets)
    local df_do = criterion:backward(outputs, targets)
    rnn:backward(inputs, df_do)
    --clip gradients
    rnn:gradParamClip(5)
    return f,gradParameters
  end
  -- keep avg loss
  local loss = 0
  for iter = 1, trainDB.dim[1] do
    parameters, f = optim.adam(feval, parameters, optimState)
    xlua.progress(iter, trainDB.dim[1])
    if iter % opt.printEvery == 0 then
      print('Iter: '..iter..', loss: '..loss )
    end
    loss = loss + f[1]
  end
  return loss / trainDB.dim[1]
end

function test()
  rnn:evaluate()
  -- keep avg loss
  local loss = 0
  local outputHist = {}
  local targetHist = {}
  for iter = 1, valDB.dim[1] do
    inputs, targets = valDB:getBatch()
    inputs = inputs:resize(1,opt.rho,dataDim):cuda()
    targets = targets[{{},-1,{}}]:resize(1, valDB.ldim[2]):cuda() --bs = 1 on test (FIXME?)
    local outputs = rnn:forward(inputs)
    if opt.plotRegression ~= 0 then
      outputHist[iter] = outputs:float():view(-1)
      targetHist[iter] = targets:float():view(-1)
    end
    local f = criterion:forward(outputs, targets)    
    xlua.progress(iter, valDB.dim[1])
    loss = loss + f
  end
  if (epoch % opt.plotRegression) == 0 then
    outputHist = nn.JoinTable(1,1):forward(outputHist)
    targetHist = nn.JoinTable(1,1):forward(targetHist)
    -- edge efects if rho > 1 because we need rho frames to predict the last one
    gnuplot.plot({'outputs', outputHist, '~'},{'targets', targetHist, '~'})
  end
  return loss / valDB.dim[1], outputs
end

while epoch < opt.maxEpoch do
  print('epoch '..epoch..':')
  print('Train:')
  local trainLoss = train()
  print('Avg train loss: '..trainLoss)
  local testLoss = nil
  if (epoch % opt.testEvery) == 0 then
    print('Test:')
    testLoss = test()
    print('Avg test loss: '..testLoss)
  end
  logger:add({epoch, trainLoss, testLoss})
  epoch = epoch + 1
  if (epoch % opt.saveEvery) == 0 then
    torch.save('model.t7',lightModel)
  end
end