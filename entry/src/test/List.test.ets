import localUnitTest from './LocalUnit.test';
import agentRuntimeTest from './AgentRuntime.test';
import agentMemoryStoreTest from './AgentMemoryStore.test';
import agentPermissionMatrixTest from './AgentPermissionMatrix.test';
import searchIndexTest from './SearchIndex.test';
import fullTextSearchServiceTest from './FullTextSearchService.test';

export default function testsuite() {
  localUnitTest();
  agentRuntimeTest();
  agentMemoryStoreTest();
  agentPermissionMatrixTest();
  searchIndexTest();
  fullTextSearchServiceTest();
}
