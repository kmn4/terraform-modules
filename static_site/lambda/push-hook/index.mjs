import { CodeBuildClient, StartBuildCommand } from '@aws-sdk/client-codebuild';

export async function handler(event) {
  try {

    const record = event.Records[0];

    const region = record.awsRegion;
    if (!region) throw new Error('missing region');

    const projectName = record.customData;
    if (!projectName) throw new Error('missing project name');

    const client = new CodeBuildClient({ region });

    for (const item of record.codecommit.references) {
      const branch = item.ref;
      if (!branch) throw new Error('missing branch name');

      await client.send(new StartBuildCommand({
        projectName,
        sourceVersion: branch
      }));
    }

  } catch (error) {
    console.log("error: " + JSON.stringify(error.message));
    return {
      statusCode: 500,
      body: JSON.stringify(error.message)
    };
  }

  return {
    statusCode: 204,
    body: ''
  };
}
