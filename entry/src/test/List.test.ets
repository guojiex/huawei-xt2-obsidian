import localUnitTest from './LocalUnit.test';
import agentRuntimeTest from './AgentRuntime.test';
import agentMemoryStoreTest from './AgentMemoryStore.test';
import agentPermissionMatrixTest from './AgentPermissionMatrix.test';
import agentConfigStoreTest from './AgentConfigStore.test';
import agentConversationStorageTest from './AgentConversationStorage.test';
import agentOperationStorageTest from './AgentOperationStorage.test';
import recentErrorStoreTest from './RecentErrorStore.test';
import searchIndexTest from './SearchIndex.test';
import fullTextSearchServiceTest from './FullTextSearchService.test';
import wikiLinkParserTest from './WikiLinkParser.test';
import wikiLinkServiceTest from './WikiLinkService.test';

export default function testsuite() {
  localUnitTest();
  agentRuntimeTest();
  agentMemoryStoreTest();
  agentPermissionMatrixTest();
  agentConfigStoreTest();
  agentConversationStorageTest();
  agentOperationStorageTest();
  recentErrorStoreTest();
  searchIndexTest();
  fullTextSearchServiceTest();
  wikiLinkParserTest();
  wikiLinkServiceTest();
}
