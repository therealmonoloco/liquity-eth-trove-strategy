// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IHintHelpers {
  function getApproxHint(uint _CR, uint _numTrials, uint _inputRandomSeed)
          external
          view
          returns (address hintAddress, uint diff, uint latestRandomSeed);
}
