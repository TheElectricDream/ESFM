function tests=test_observation_pose
tests=functiontests(localfunctions);
end

function setupOnce(testCase)
root=fileparts(fileparts(mfilename('fullpath')));
testCase.applyFixture(matlab.unittest.fixtures.PathFixture(root));
end

function testSingleAndMultipleObservationsMatchPublicPose(testCase)
cfg=config(); tr=traj.create_trajectory(0,20,1);
tr.k=sin((1:tr.K)'/3)*.02;
tr.m=[sin((1:tr.K)'/4),cos((1:tr.K)'/3),(1:tr.K)']/1000;
tr.V=[.002 -.001 .0005];
cam=struct('focal',[500 500],'principal',[320 240]);
X=[.1 .02 .03];
for times={7.35,[1.25;7.35;10.05]}
    t=times{1}; O=[t,ones(numel(t),1),repmat([350 240 1 0],numel(t),1)];
    prob=adjust.setup_problem(tr,X,O,(1:8)',[],cam,cfg.adjust);
    [R,T,theta]=adjust.observation_pose(prob,tr);
    [expected_R,expected_T]=traj.pose(tr,t);
    verifySize(testCase,T,[numel(t),3]);
    verifySize(testCase,theta,[numel(t),1]);
    verifyEqual(testCase,T,expected_T,'AbsTol',1e-14);
    verifyEqual(testCase,theta,traj.angle(tr,t),'AbsTol',1e-14);
    fields=fieldnames(R);
    for j=1:numel(fields)
        verifyEqual(testCase,R.(fields{j}),expected_R.(fields{j}),'AbsTol',1e-14);
    end
end
end
