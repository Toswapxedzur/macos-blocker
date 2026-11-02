window.runTagParentTests = async () => {
  const scope = document.getElementById("host").shadowRoot;
  const q = selector => scope.querySelector(selector);
  const check = (value, label) => { if (!value) throw Error(label); };
  const wait = () => new Promise(resolve => setTimeout(resolve, 40));
  testState.assets.trees[0].nodes.push({
    id: "tag-2", name: "Child", description: "", parentID: null,
    positionX: 190, positionY: 24
  });
  pushSnapshot();
  await wait();
  q('[data-action="selectType"]').click();
  q('.tree-map-node[data-node-id="tag-2"]').click();
  q('[data-action="beginConnection"]').click();
  check(q(".tree-connection-mode"), "Set parent did not enter parent selection");
  q('.tree-map-node[data-node-id="tag-1"]').click();
  const connection = commands.findLast(item => item.action === "connectTag");
  check(connection?.data.nodeID === "tag-2" && connection.data.parentID === "tag-1",
    "Set parent did not submit the chosen parent");
  testState.assets.trees[0].nodes[1].parentID = "tag-1";
  pushSnapshot();
  await wait();
  q('.tree-map-node[data-node-id="tag-2"]').click();
  q('[data-action="disconnectTag"]').click();
  check(commands.findLast(item => item.action === "disconnectTag")?.data.nodeID === "tag-2",
    "Remove parent did not submit");
  testState.assets.trees[0].nodes[1].parentID = null;
  pushSnapshot();
  await wait();
  q('.tree-map-node[data-node-id="tag-2"]').click();
  q('[data-action="deleteTag"]').click();
  q('[data-action="deleteTag"]').click();
  check(commands.findLast(item => item.action === "deleteTag")?.data.nodeID === "tag-2",
    "Delete tag did not submit after confirmation");
  check(uiErrors.length === 0, uiErrors.join("\n"));
  return [
    "PASS Set parent selects and submits the parent",
    "PASS Remove parent submits",
    "PASS Delete tag submits after confirmation",
    "PASS no Classifier script errors"
  ];
};
