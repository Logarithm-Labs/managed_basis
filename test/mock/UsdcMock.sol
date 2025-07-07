import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract UsdcMock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
