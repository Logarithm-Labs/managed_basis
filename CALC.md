

spotExecutionPrice = 71376360000
hedgeExecutionPrice = 71376360000 * 0.98 = 69948832800
sizeDeltaInTokens = 2 BTC = 2 * 1e10

executionCost = (71376360000 - 69948832800) * 2 * 1e12 = 


nominal spread = 71376.360000 - 69948.832800 = 1427.527199
nominal cost = 2 * 1427.527199 = 2855.054398

realCost = 2855054398
realSpread = 71376360000 - 69948832800 = 1427527200
realCost = realSpread * sizeDeltaInTokens / indexDecimals = 1427527200 * 2 * 1e12 / 1e12

executionAmount = sizeDeltaInTokens / targetLeverage * exectuionPrice

nominal execution amount = 2 * 69948.832800 / 3 = 46632.5552
realExecutionAmount = 46632555200
realExecutionAmount = 2 * 1e10 * 69948832800 * 1e18 / (3 * 1e18 * 1e10) = 


