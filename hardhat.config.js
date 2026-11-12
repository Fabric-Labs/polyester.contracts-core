/**
 * Compile-only configuration. Compiler settings and the sources path match the
 * deployment build, so source unit names and bytecode stay comparable.
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    compilers: [
      {
        version: '0.8.22',
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    ],
  },
  paths: {
    sources: './src/active',
  },
};
